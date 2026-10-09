# Spikes (Phase 0, go/no-go)

Throwaway VMs are created and destroyed with vm-service (`vm_service create-vm … --no-backup` / `destroy-vm`; templates debian13 = 9000, rhel10 = 9010, x86_64 only). aarch64 checks run on `pi7`. No RHEL 10 aarch64 host exists yet. Record results here, then write or confirm the ADRs.

| Spike | Question | Go criterion |
|---|---|---|
| [S1](S1-packages.md) | Do the packages exist for every target? | `cvmfs` + `cvmfs-server` on Debian 13 amd64/arm64 and EL10 x86_64/aarch64; mergerfs on all four; MinIO S3 API port known |
| [S2](S2-union-store.md) | Does the mergerfs union store work with Nix on top? | `spikes/s2-union-store.sh` passes on Debian 13 and RHEL 10, x86_64 and aarch64 |
| [S3](S3-mkfs-minio.md) | Does `cvmfs_server mkfs` + publish work against MinIO? | A client probes the repository through the Cache |

S2 is the one that decides the host model (ADR 0002). If it fails, `cvmfs_nix_mode=cache` is primary.
