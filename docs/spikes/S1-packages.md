# S1 — package availability

Already verified from the cernvm repository indexes (2026-10-08):

| Target | `cvmfs` | `cvmfs-server` | mergerfs |
|---|---|---|---|
| Debian 13 amd64 | 2.14.1 | yes | 2.40.2 (distro) |
| Debian 13 arm64 | 2.14.1 | yes | 2.40.2 (distro) |
| EL10 x86_64 | 2.14.1 | yes | upstream RPM — **confirm `el10.x86_64` asset exists** |
| EL10 aarch64 | 2.14.1 | yes | upstream RPM — **confirm `el10.aarch64` asset exists** |

To do on the VMs:
- [ ] `apt install cvmfs cvmfs-server` on Debian 13 (amd64 + arm64) via `cvmfs-release-latest_all.deb` — confirm the URL in `cvmfs_client/defaults`.
- [ ] `dnf install cvmfs` on RHEL 10 via `cvmfs-release-latest.noarch.rpm`.
- [ ] mergerfs RPM for el10 on both arches (fallback: build once from upstream, host in the `cvmfs` bucket under `bootstrap/`).
- [ ] MinIO S3 API port on filer1 (the console is 9002). Record in `server/minio/RUNBOOK.md` §1.4 and the role defaults.
- [ ] Determinate installer on RHEL 10 aarch64 and Debian 13 arm64: `nix --version` ≥ 2.22.

Result: _pending_
