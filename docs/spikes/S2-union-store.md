# S2 — mergerfs union store with Nix on top (go/no-go for ADR 0002)

Needs S3 done (a real repository to mount) or a stand-in: any read-only directory tree that can be
swapped underneath (the script accepts a plain directory as the RO branch and simulates a "revision
flip" by replacing it with `mv`).

Run `spikes/s2-union-store.sh` as root on each of: Debian 13 x86_64, Debian 13 arm64 (pi7), RHEL 10
x86_64. (aarch64 is Pis only, and they run only Debian.) It checks:

1. mergerfs mounts with the role's option set; `findmnt /nix/store` is `fuse.mergerfs`.
2. An executable on the RO branch runs (mmap works with `cache.files=auto-full`).
3. `nix store info` succeeds with the `local-overlay://…check-mount=false` store URL.
4. `nix build nixpkgs#hello` lands in the RW branch; `nix-collect-garbage -d` removes it and nothing on RO.
5. **Revision flip**: while a process from the RO branch is running, the RO branch is replaced
   (new content, new inodes); a path that did not exist before is found without remount; the running
   process survives; `dmesg` shows no FUSE errors; no ESTALE anywhere.
6. Exec latency: `hyperfine` on a small binary via the union vs directly — record the numbers.
7. A new daemon connection sees paths added to the lower DB after the daemon started.

Record per host: kernel, mergerfs version, Nix version, pass/fail per step, latency numbers.

Result: _pending_
