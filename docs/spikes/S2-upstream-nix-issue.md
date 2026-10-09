# Draft upstream issue for NixOS/nix (not filed yet)

Filing it is an outward-facing step; the text is kept here until that decision is made.

---

**Title:** Sandboxed builds fail on a FUSE store (mergerfs): the chroot parent `<drv>.chroot` is 0700, which path-based FUSE filesystems cannot traverse as the build user

**Describe the bug**

With the store directory on a path-based FUSE filesystem (mergerfs, with `local-overlay-store` over a
read-only lower store), every sandboxed build fails with ENOENT inside the sandbox, e.g.
`error: executing '/bin/sh': No such file or directory` or
`sh: can't create /nix/store/<out>: nonexistent directory`. Unsandboxed builds work.

Cause: the sandbox is created at `<realStoreDir>/<drv>.chroot` with mode **0700** (root-only), and
`root/` inside it is 0750 root:nixbld
(`src/libstore/unix/build/linux-derivation-builder.cc`, `mkdir(chrootParentDir.c_str(), 0700)`, Nix 2.30.0;
the same mode is observed on 2.35.2). After `pivot_root`, path walks on a kernel filesystem start at
the `root/` inode and never traverse `.chroot`, so the mode does not matter. A path-based FUSE
filesystem re-resolves the full path on its backing directories as the calling uid
(mergerfs does `setfsuid` for every request): `<branch>/<drv>.chroot/root/bin/sh`. The build user
cannot traverse the 0700 directory; mergerfs's search policy treats EACCES as "not on this branch"
and returns ENOENT.

**Steps to reproduce** (Nix 2.30.0 and 2.35.2, mergerfs 2.40.2, Linux 6.12 / 6.18, x86_64 and aarch64)

1. `/nix/store` is a mergerfs union: `mergerfs -o category.create=ff,allow_other,... /nix/.rw-store/store=RW:/srv/lower/nix/store=RO /nix/store`
2. `nix-daemon --option store 'local-overlay://?lower-store=local%3Froot%3D%2Fsrv%2Flower%26read-only%3Dtrue&upper-layer=/nix/.rw-store/store&check-mount=false'`
3. `nix build --impure --expr 'derivation { name = "t"; system = builtins.currentSystem; builder = "/bin/sh"; args = [ "-c" "echo hi > $out" ]; }'`

Confirmations:
- No Nix involved: a 0700 directory with a 0750 root:nixbld child, bind-mounted and read as `nixbld1`:
  on xfs `ls`/`cat` work; on mergerfs they return ENOENT; with the parent at 0711 they work.
- A watcher that `chmod 711`s `<drv>.chroot` the instant it appears makes the build succeed.
- `build-users-group =` (builder runs as uid 0 inside the sandbox) also makes it succeed.

**Expected behavior**

Sandboxed builds work on any filesystem Nix can otherwise use as a store.

**Proposed fix**

Make the chroot parent traversable by the build group: `0710` owned `root:<build gid>` (or `0711`).
`root/` is already 0750 root:nixbld (or 0755 build-uid with uid ranges), so other users gain no access
to the sandbox contents. Happy to open a PR.

**Metadata:** `nix (Nix) 2.30.0` (Determinate installer 3.8.0) and `2.35.2`; Debian 13, RHEL 10.2.
