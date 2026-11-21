# Runbook: /nix/store says "Read-only file system" on a Union Store host

Symptoms: on a host in union Mode, `nix develop`, `nix build`, `nix store add-file` or a substitution fail
with `error: … '/nix/store/…': Read-only file system`. Reads, and the Profiles, keep working.

The union is not read-only: the RW Branch has dropped under mergerfs's free-space floor (`minfreespace`).
Below it mergerfs puts no new file in the RW Branch, and the only branch left is the read-only Lower
Store, so every create fails with `EROFS` (#81).

1. Look: `df -h /nix/.rw-store` (the RW Branch lives on `/`), and the floor the mounted union has:
   `sudo getfattr --only-values -n user.mergerfs.minfreespace /nix/store/.mergerfs` (bytes).
2. A floor of `4294967295` (4 GiB, mergerfs's own default) means a union mounted before #81: re-run
   "cvmfs: clients" for the host. `tasks/union_free_space.yml` lowers it to `nix_union_minfreespace`
   (1G) live, without a remount.
3. Free space: `sudo systemctl start nix-gc.service` (the weekly GC, `--delete-older-than 30d`), then
   anything else on `/`, such as old journals or Docker images. The CVMFS client cache also lives
   on `/` (`/var/lib/cvmfs`): a host short on space gets a lower `cvmfs_quota_limit_mb` in NetBox.
4. Check: `df -h /`, then a write, `echo hi > /tmp/t && nix store add-file /tmp/t`.

The floor (1G) stays under Nix's `min-free` (2G): Nix's GC runs while the RW Branch still takes writes,
and the role refuses a run that sets it otherwise.
