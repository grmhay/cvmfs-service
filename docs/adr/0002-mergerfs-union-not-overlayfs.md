# The union store is mergerfs over CVMFS, not kernel overlayfs

Nix's `local-overlay-store` (Nix ≥ 2.22) was written for kernel overlayfs: a read-only lower store
with a writable upper layer. Using CVMFS as that lower layer is exactly our model, but kernel
overlayfs caches lower dentries and inodes and never revalidates them, and it declares a changing
lower layer undefined behaviour. CVMFS renumbers inodes on every repository revision and may replace
symlinks. After a publish, an overlayfs client keeps stale negative dentries for paths that now exist
and returns ESTALE for paths it had seen; the only remedy is a remount of `/nix/store`, which cannot
happen on a host that is executing anything from it. Nobody has published a working Nix-over-CVMFS
overlayfs setup; EESSI uses fuse-overlayfs, and only on build nodes.

`/nix/store` is therefore assembled by **mergerfs**: `/nix/.rw-store/store=RW` over
`/cvmfs/nix.hayweb.org/nix/store=RO`, `category.create=ff`, `inodecalc=path-hash`,
`cache.negative_entry=0`, `cache.entry=1`, `cache.files=auto-full`. mergerfs is a FUSE union that
re-resolves every lookup against its branches and synthesises its own stable inodes, so a revision
flip is simply new files on the RO branch — no remount, no stale entries. The Nix daemon runs a
`local-overlay-store` on top with `check-mount=false` and the RW branch as its upper layer.

## Considered Options

- **Kernel overlayfs (as Nix intends)** — rejected for the reasons above: correct only until the
  first publish, and unrecoverable on a live host.
- **Binary cache + ordinary local `/nix`** — removes the union entirely at the cost of copying every
  used closure locally and a per-host install step. Kept as the fallback `cache` Mode; the owner chose
  the zero-copy model as primary knowing this trade.
- **Remount + daemon restart after every publish** — the daemon restart turned out to be unnecessary
  (each daemon connection opens the lower SQLite afresh), and the remount is impossible while any
  process runs from the store. Rejected.
- **fuse-overlayfs** — avoids the kernel's lower-layer caching but still implements overlay semantics
  (copy-up, whiteouts) we do not need, and has had its own bugs over CVMFS. mergerfs is simpler.

## Consequences

- `local-overlay-store` on a non-overlayfs mount is unsupported by Nix. It works because Nix never
  deletes lower paths (no whiteouts needed) and the upper layer is a plain directory, so Nix's
  upper/lower checks hold. A Nix upgrade can break this; `nix_installer_version` is pinned and bumped
  deliberately, and `nix store info` after upgrade is part of the role.
- Every exec and read of a published path crosses two FUSE layers (mergerfs → cvmfs). CVMFS's own
  kernel caching keeps this cheap, but it is measurable; spike S2 records the numbers.
- `cache.files=auto-full` is required so executables can be mmapped. The option set in
  `nix_union_store/defaults/main.yml` is the output of spike S2, not a guess to be tuned ad hoc.
- Local GC deletes only from the RW Branch; the Lower Store is immutable to the host.
- mergerfs must be present before Nix starts: `nix-store.mount` is ordered before `nix-daemon`, and
  the CVMFS mount is static (fstab, no autofs) so `RequiresMountsFor` can hold it.
- RHEL 10 has no distro mergerfs package; the role installs the upstream RPM.
- **Nix's build sandbox does not work on the union** (spike S2): Nix creates the chroot as
  `<store>/<drv>.chroot` with mode 0700, and mergerfs resolves every path on its branches as the build
  user, so the sandboxed builder gets ENOENT for everything. Until upstream makes that directory
  traversable by the build group, union-mode hosts run with `sandbox = false`
  (`nix_union_sandbox: "false"`; the alternative `build-users-group =` keeps the sandbox but builds as
  root). The Publisher and the builders have plain stores and keep the sandbox.
