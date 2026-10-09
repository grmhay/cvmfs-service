# S1 — package availability

Repository indexes checked 2026-10-08; installs run 2026-10-09 with `spikes/s1-packages.sh` on
throwaway VMs from vm-service (templates 9000 / 9010), after buildhost-all had configured them.

| Target | `cvmfs` + `cvmfs-server` | mergerfs | Nix (installer v3.8.0) | Result |
|---|---|---|---|---|
| Debian 13 x86_64 (kernel 6.12.95) | 2.14.1 (cernvm apt) | 2.40.2 (distro) | 2.30.0 | pass 5/5 |
| RHEL 10.2 x86_64 (kernel 6.12.0-211) | 2.14.1 (cernvm yum) | 2.40.2 (upstream el10 RPM) | 2.30.0 | pass 7/7 |
| Debian 13 arm64, pi7 (kernel 6.18.50+rpt-rpi-v8) | 2.14.1 (cernvm apt) | 2.40.2 (distro) | 2.30.0 | pass 5/5 |

Findings:
- **The Debian 13 template has no `curl`.** The `nix_union_store` role piped the Determinate installer through `curl`; it now installs `curl` first.
- **RHEL needs buildhost-all to have run.** A fresh clone is not registered and has no repos. cvmfs depends on `fuse`, `autofs`, `gdb` and `lsof`; mergerfs depends on `fuse`. After buildhost-all, BaseOS, AppStream and EPEL are enabled and everything installs. Roles must therefore run after buildhost-all, which is already the case: buildhost-all is the post-create step and the fleet playbooks run later.
- **Installer v3.8.0 installs upstream Nix 2.30.0**, not Determinate Nix. `local-overlay-store` and `read-only-local-store` are available.
- mergerfs from Debian reports `vunknown` for `--version`; `dpkg-query -W mergerfs` gives 2.40.2-5.
- Release-package URLs in the role defaults are correct (HTTP 200): `cvmfs-release-latest_all.deb`, `cvmfs-release-latest.noarch.rpm`, `mergerfs-2.40.2-1.el10.x86_64.rpm`. Upstream also ships el10 aarch64 RPMs (not needed: aarch64 is Debian-only).

Still to do:
- [x] Run on pi7 (Debian 13 arm64).
- [ ] MinIO S3 API port on filer1 (the console is 9002). Record in `server/minio/RUNBOOK.md` §1.4 and the role defaults.

Result: **pass on all three targets** (MinIO S3 API port still to record)
