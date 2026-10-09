# S2 — mergerfs union store with Nix on top (go/no-go for ADR 0002)

Needs S3 done (a real repository to mount) or a stand-in: any read-only directory tree that can be
swapped underneath. The script accepts a plain directory as the RO branch and simulates a "revision
flip" by replacing it with `mv`.

Run `spikes/s2-union-store.sh` as root on each of: Debian 13 x86_64, Debian 13 arm64 (pi7), RHEL 10
x86_64. (aarch64 is Pis only, and they run only Debian.) It checks:

1. mergerfs mounts with the role's option set; `findmnt /nix/store` is `fuse.mergerfs`.
2. An executable on the RO branch runs (mmap works with `cache.files=auto-full`).
3. The daemon serves the `local-overlay://` store (configured as the role does) and a lower path is valid.
4. `nix build` lands in the RW branch; a minimal derivation builds locally **with and without the
   sandbox**; `nix-collect-garbage -d` removes RW paths and nothing on RO.
5. **Revision flip**: while a process from the RO branch is running, the RO branch is replaced
   (new content, new inodes); a path that did not exist before is found without remount; the running
   process survives; `dmesg` shows no FUSE errors; no ESTALE anywhere.
6. Exec latency: `hyperfine` on a small binary via the union vs directly.
7. A new daemon connection sees paths added to the lower DB after the daemon started.

## Results (2026-10-09, plain-directory stand-in for the lower store)

| Host | Kernel | mergerfs | Nix | 1 | 2 | 3 | 4 build/GC | 4 sandboxed local build | 5 | 7 | exec latency (direct / union) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| RHEL 10.2 x86_64 | 6.12.0-211.7.3.el10_2 | 2.40.2 | 2.30.0 | ok | ok | ok | ok | **FAIL** | ok | ok | 651 µs / 677 µs |
| Debian 13 x86_64 | 6.12.95+deb13 | 2.40.2-5 | 2.35.2¹ | ok | ok | ok | ok | **FAIL** | ok | ok | 1.3 ms / 1.3 ms |
| Debian 13 arm64 (pi7) | 6.18.50+rpt-rpi-v8 | 2.40.2-5 | 2.30.0 | ok | ok | ok | ok | **FAIL** | ok | ok | 6.9 ms / 7.8 ms² |

¹ Upgraded from 2.30.0 on this VM while isolating the read-only-store failure; same results.
² Within run-to-run variation (±1.2 / ±1.5 ms). pi7 was returned to a plain `/nix/store` afterwards; cvmfs, mergerfs and Nix stay installed.

Exec through the union costs nothing measurable. The revision flip works with no remount, no ESTALE
and no dmesg noise, which was the main risk ADR 0002 accepted.

## Findings that changed the design

1. **The lower DB must not be in WAL mode.** A `read-only=true` lower store is opened by SQLite as
   `immutable`, which ignores the `-wal` file. After `nix copy` the data is still in `db.sqlite-wal`
   (32 MB WAL against a 4 KB `db.sqlite`), so clients see an empty store. Symptoms: Nix 2.30 fails
   with `create table if not exists SchemaMigrations … attempt to write a readonly database`; Nix 2.35
   fails with `no such table: ValidPaths` (the same symptom as NixOS/nix#16475). **Fix:**
   `publish.sh` runs `PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;` on the lower DB
   before every publish. After that, both versions work, and a path added later (followed by a
   checkpoint) is valid from a new daemon connection with no restart.
2. **`read-only-local-store` is a separate experimental feature** from `local-overlay-store`; both
   are needed. Added to `nix.conf`.
3. **Clients must go through the daemon.** With `store = local-overlay://…` in `nix.conf`, non-root
   clients open the store directly and fail on `/nix/var/nix/db/big-lock`, and root bypasses the
   daemon. **Fix:** `nix.conf` has `store = daemon`; the overlay URL goes only to `nix-daemon`
   (`--option store …` in a systemd drop-in).
4. **No `root=/` in the overlay URL.** It makes the real store dir `//nix/store`, which Nix treats as
   a chroot store, redirecting every build output to `//nix/store/<drv>.chroot/root/…` ("failed to
   produce output path"). Dropped from the role and the script.

## Open: sandboxed local builds fail on the union

Fails on all three hosts (x86_64 and arm64) and on both Nix 2.30 and 2.35. Unsandboxed builds work. Nix places the build
chroot under the real store dir (`/nix/store/<drv>.chroot`), which is the mergerfs mount. Inside the
sandbox, `/` and `/nix/store` are bind mounts of that FUSE subtree. `stat` works, but `readdir` and
create fail (`sh: can't create /nix/store/…: nonexistent directory`; inputs such as `/bin/sh` are
"No such file or directory").

Not the cause:
- user namespaces: an unprivileged user in `unshare -Ur` can list and create through the union;
- FUSE bind mounts as such: a bind mount of a union subdirectory in a mount namespace works for root.

Substituted packages are unaffected; only derivations that must be built locally hit this. Fleet
hosts consume published Profiles, while the Publisher and the builders use plain stores, so local
builds on union hosts are rare. Options:
- `sandbox = false` on union-mode hosts only.
- Find the cause: Nix's sandbox mount sequence (`pivot_root` into a FUSE subtree, `MS_PRIVATE`
  propagation) against mergerfs, or upstream.
- Make `cvmfs_nix_mode=cache` primary instead.

Result: **conditional go on all three targets.** Everything except sandboxed local builds works.
