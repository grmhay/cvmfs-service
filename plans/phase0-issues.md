# Phase 0 issues (prerequisites + spikes)

Each heading is one GitHub issue; the repo it belongs to is in brackets. Labels: `needs-triage` on
creation. S1–S3 and the VM issue are `ready-for-agent`: VMs come from vm-service (`create-vm` / `destroy-vm`), not a human.
Only the MinIO bucket issue is `ready-for-human`, because it is created by hand (decision Q4c).

---

## [cvmfs-service] S1 — Verify packages for every target
Confirm, on throwaway VMs, the install path the roles assume (`docs/spikes/S1-packages.md`):
- `cvmfs` + `cvmfs-server` 2.14.1 via `cvmfs-release-latest_all.deb` on Debian 13 amd64 and arm64; via `cvmfs-release-latest.noarch.rpm` on RHEL 10 x86_64 and aarch64 — confirm the release-package URLs in `ansible/roles/cvmfs_client/defaults/main.yml`.
- mergerfs: Debian 13 distro package (2.40.2); RHEL 10 upstream RPM — confirm an `el10.{x86_64,aarch64}` asset exists for the pinned `mergerfs_version`; if not, build once and host under `bootstrap/` in the bucket.
- Determinate Nix installer on RHEL 10 aarch64 and Debian 13 arm64 → `nix --version` ≥ 2.22.
- MinIO S3 **API** port on filer1 (console is 9002) → record in `server/minio/RUNBOOK.md` §1.4 and both role defaults.
Done when: the table in `docs/spikes/S1-packages.md` is filled and the defaults are corrected.

## [cvmfs-service] S2 — mergerfs union store + Nix local-overlay-store (go/no-go, ADR 0002)
Run `spikes/s2-union-store.sh` on Debian 13 x86_64, Debian 13 arm64 (a Pi), RHEL 10 x86_64, RHEL 10 aarch64. Steps 1–7 in `docs/spikes/S2-union-store.md`: mount, mmap exec, `nix store info`, local build + GC isolation, revision flip under load (no stale entries, process survives, dmesg clean), exec latency numbers, new-daemon-connection sees new lower DB.
Done when: pass/fail + numbers recorded per host; mergerfs option set in `nix_union_store/defaults` updated from the results; ADR 0002 confirmed or `cvmfs_nix_mode: cache` made the default.

## [cvmfs-service] S3 — `cvmfs_server mkfs` against MinIO, publish, read through nginx
On a throwaway Debian 13 VM with a **scratch bucket** `cvmfs-spike`: mkfs with the role's `s3.conf`, one transaction publishing `nixpkgs#hello` for both systems into the lower store and the binary cache, objects visible in the bucket, nginx role on the same VM serving `.cvmfspublished` (200) and `X-Cache-Status: HIT` on a `data/` object, a second VM probing through nginx. Then `rmfs` and delete the bucket. Known pitfalls in `docs/spikes/S3-mkfs-minio.md`.
Done when: checklist complete; any config deltas folded into `cvmfs_publisher` / `cvmfs_nginx_cache`.

## [cvmfs-service] MinIO: bucket, policy, publisher service account (by hand)
Follow `server/minio/RUNBOOK.md` §2 after the rename/cert issue below lands: `cvmfs` bucket, anonymous `s3:GetObject` on `cvmfs/*` (no listing), `cvmfs-publisher` service account scoped to the bucket; keys into `secrets/publisher.enc.yaml`. Verify with `nix run .#verify-origin` from a LAN host and a cloud host.
Blocked by: the ops-repo cert issue.

## [cvmfs-service] Create publisher, cache1 and canary VMs with vm-service
`vm_service create-vm` from the packer templates (debian13 = 9000, rhel10 = 9010). vm-service has no disk-size option; check the template disk and add a data disk or a vm-service disk-resize feature if needed: `publisher` (Debian 13 x86_64, 4 vCPU / 8 GB / 100 GB), `cache1` (Debian 13, 2 vCPU / 4 GB / 120 GB), `nixcanary-deb1` (Debian 13), `nixcanary-rhel1` (RHEL 10). Register all four in NetBox with the roles/tags from the NetBox issue. No software yet — Phase 1/2 playbooks do that.

---

## [homelab-opscontrolplane] MinIO → `minio.hayweb.org` with a Let's Encrypt cert, pushed to TrueNAS
- Internal BIND: `minio.hayweb.org` → filer1.
- Caddy: add `minio.hayweb.org` to the DNS-01 (name.com) names.
- New stack `truenas-cert-pusher`: watches Caddy's cert for that name, pushes it to the TrueNAS API on change (API key in `secrets/prod/truenas.enc.yaml`); MinIO app set to use it.
- Loki on pi2 (hand-managed): endpoint → `https://minio.hayweb.org:<api-port>`, drop self-signed trust. Same change window; alloy buffers.
Done when: `openssl s_client -connect minio.hayweb.org:<port>` verifies; Loki ingesting; `cvmfs-service` runbook `docs/runbooks/minio-cert-cutover.md` ticked.

---

## [ansible-lab-config] NetBox as inventory source for the Nix/CVMFS roles
- NetBox: tags `nix-builder` (pi5, pi6), `nix-canary` (pi7, nixcanary-deb1, nixcanary-rhel1); custom fields on Device/VM: `nix_group` (choices base, docker-host, proxmox-node, cloud, builder), `nix_channel` (stable, canary), `cvmfs_nix_mode` (union, cache, thin), `cvmfs_quota_limit_mb` (int); device roles `nix_publisher`, `nix_cache`.
- `netbox.netbox.nb_inventory` config as in `cvmfs-service/ansible/inventory.netbox.example.yml` (if the repo is not on dynamic inventory yet, this is the migration).
- `requirements.yml`: roles from `https://github.com/grmhay/cvmfs-service.git` at a tag.
- Semaphore jobs for `publisher.yml`, `cache.yml`, `builders.yml`, `clients.yml`.
Done when: `ansible-inventory --graph` shows `tag_nix_builder`, `tag_nix_canary`, `nix_publisher`, `nix_cache` with the right hosts and host vars.

---

## Follow-ups (not Phase 0)
- [packer-service] Bake `cvmfs_client` + `nix_union_store` (no group/channel) into the Debian 13 and RHEL 10 templates — Phase 3.
- [cvmfs-service] `vm-service` as a flake input → `profile-docker-host`; retire the curl install — Phase 3.
- [ansible-lab-config] Caddy redundancy for skyline's public ingress — out of scope here, separate decision.
