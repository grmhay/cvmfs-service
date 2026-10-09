# Plan: Nix software distribution over CVMFS (MinIO-backed, nginx-cached, mergerfs union store)

## Context

Today software reaches hosts as Docker Hub images (digest-pinned via `homelab-opscontrolplane`) or
curl'd GitHub-release binaries (`vm-service`). Nix is dev-only (`nix develop`), though every flake
already builds `x86_64-linux` and `aarch64-linux`. There is no internal artifact store, no nginx, no
CVMFS, and the ~30-host fleet (Debian 13 / RHEL 10, x86_64 + aarch64, Proxmox VMs, NVMe-backed Pis,
cloud hosts over OpenVPN) is managed by Ansible/Semaphore from `ansible-lab-config`.

Goal: build Nix closures once, have every host see them on demand under `/nix/store` with CVMFS
managing a quota-bounded local cache (nothing is copied into a local `/nix` unless built locally),
MinIO as origin, an nginx cache in the homelab, and a Nix daemon still usable on every host.

### Decisions (from the grilling session, 2026-10-08/09)

| # | Decision |
|---|---|
| Scope | Own-flake closures + arbitrary nixpkgs packages + non-Nix blobs (wrapped as derivations, Q1b=B). Replacing Docker on skyline: **deferred, undecided**. |
| Repo/channels | One CVMFS repo `nix.hayweb.org`; `/profiles/<channel>/<group>/<system>`; channels `stable`, `canary`. Publish → `canary`; `promote` re-points `stable` (no rebuild) and commits the pointer. |
| Host model | **mergerfs union store primary** (`cvmfs_nix_mode=union`): `/nix/store` = mergerfs(RW local branch, RO CVMFS branch); Nix `local-overlay-store` with `check-mount=false`. Binary cache (`compression=none`) published in the same transaction as the fallback (`mode=cache`); `mode=thin` (bind-mount, no daemon) kept as a switch, unused. |
| Profiles | One composite `buildEnv` per host **group** (collisions fail at build time). Hosts put `/cvmfs/nix.hayweb.org/profiles/<channel>/<group>/<system>/bin` on PATH; systemd units reference the same path. |
| Groups | `base` (everyone, incl. Pis), `docker-host`, `proxmox-node`, `cloud`, `builder`. |
| Canary | `pi7`, `nixcanary-deb1` (Debian 13), `nixcanary-rhel1` (RHEL 10). |
| Builders | `pi5`, `pi6` (aarch64) as Nix remote builders of the publisher; `nixbuild` user, key in SOPS. |
| Publisher | New Proxmox VM, Debian 13 x86_64, 4 vCPU / 8 GB / 100 GB. |
| Origin | Existing MinIO (TrueNAS app on `filer1`, hand-built). Renamed to `minio.hayweb.org` with a Let's Encrypt cert issued by skyline's Caddy (name.com DNS-01) and pushed to the TrueNAS API by a small pusher stack in the ops repo. Loki (hand-managed on pi2) cut over in the same window. Bucket/policy/key created by runbook; roles only verify. |
| Cache | Dedicated VM `cache1.hayweb.org`, Debian 13, 2 vCPU / 4 GB / 120 GB, nginx reverse cache (`max_size` 100 GB), plain HTTP. Cloud hosts use it directly over OpenVPN (internal DNS pushed); per-cloud caches are a documented later upgrade. |
| Trigger | Publisher pulls `cvmfs-service` master every 5 min, publishes when inputs changed (reconciler pattern). Self-hosted runner later. |
| Inputs | `flake.lock` bumped by Renovate; CI builds x86_64 + evaluates aarch64; real aarch64 build on the publisher gates the publish. Service packages enter as flake inputs (`github:grmhay/vm-service/vX.Y.Z`). |
| Retention | Never delete store paths in year one. |
| Nix | Determinate installer, version pinned in the role (≥ 2.22), fleet-wide upgrades via Ansible. |
| Local GC | Weekly `nix-collect-garbage --delete-older-than 30d` timer + `min-free`/`max-free`. |
| TTL / quota | `CVMFS_REPOSITORY_TTL` default (4 min). `CVMFS_QUOTA_LIMIT`: Pis 10 GB, VMs 20 GB, cloud 20 GB, builders/publisher 50 GB (role vars). |
| Inventory | NetBox is source of truth: tags `nix-builder`, `nix-canary`; custom field `nix_group`, `nix_channel`; `ansible-lab-config` consumes via `netbox.netbox.nb_inventory` (migration is a Phase-0 prerequisite if not already in place). Role delivered via `requirements.yml` git tag. |
| Packer | Debian 13 and RHEL 10 templates bake cvmfs client, mergerfs, Nix, and static role config. |
| Secrets | Anonymous-read bucket OK (CVMFS signs). MinIO rw key, repo master key, `nixbuild` key, TrueNAS API key in SOPS, same age recipient as the ops repo. Master key decrypted only during `resign`. |
| Repo | `github.com/grmhay/cvmfs-service`, public. PRD via `/to-prd` → `/to-issues` once the repo exists; ADRs lazily. |
| Out of scope | Caddy redundancy for skyline's public ingress (Q34=C) — separate follow-up. |

### Facts verified (2026-10-08)
- CVMFS 2.14.1 packages: Debian 13 amd64+arm64 (client **and** `cvmfs-server`), EL10 x86_64+aarch64, EL9 both. `cvmfs-gateway` missing on Debian arm64 (not needed). Repo hosts: `cvmrepo.s3.cern.ch` (apt/yum), `cvmrepo.web.cern.ch` (browse). ([docs](https://cvmfs.readthedocs.io/en/stable/apx-package-repos/))
- No zstd in CVMFS (`CVMFS_COMPRESSION_ALGORITHM` = default|none). Default repo TTL 4 min; client `CVMFS_KCACHE_TIMEOUT` 1 min.
- Nix `local-overlay-store` (+`remount-hook`, `check-mount`) since 2.22; `read-only` lower store since 2.17. ([manual](https://nix.dev/manual/nix/latest/store/types/experimental-local-overlay-store))
- Nobody has published Nix-overlay-over-CVMFS. Kernel overlayfs over a changing CVMFS lower is undefined (inode renumbering per revision, cached negative dentries, ESTALE; remount impossible on a live host). **This is why the union is mergerfs, not overlayfs.**
- mergerfs: Debian 13 ships 2.40.2 (amd64, arm64); upstream 2.42; RHEL 10 → upstream RPMs (el10.aarch64 availability = spike S1 item; fallback: build once, host RPM in the bucket).
- Determinate installer: any systemd Linux, x86_64/aarch64.

## Architecture

```
cvmfs-service PR (Renovate / promote) ─▶ master ─▶ publisher VM (5-min pull; Debian 13 x86_64; builders=ssh://nixbuild@pi5,pi6)
   nix build .#profiles.<group> for x86_64-linux + aarch64-linux
   cvmfs_server transaction nix.hayweb.org
     nix copy --to local?root=/cvmfs/nix.hayweb.org  <paths>            # /nix/store + /nix/var/nix/db (lower store)
     nix copy --to file:///cvmfs/nix.hayweb.org/cache?compression=none  # fallback binary cache
     ln -sfn <store path> /cvmfs/nix.hayweb.org/profiles/canary/<group>/<system>
   cvmfs_server publish      (S3 upstream → MinIO bucket cvmfs @ https://minio.hayweb.org)
                                          │
   cache1.hayweb.org (nginx reverse cache, http) ◀── LAN hosts, cloud hosts (OpenVPN, pushed DNS)

client: /cvmfs/nix.hayweb.org  (fstab, cvmfs FUSE, LRU quota)
        /nix/store = mergerfs  /nix/.rw-store/store=RW : /cvmfs/nix.hayweb.org/nix/store=RO
        nix-daemon store = local-overlay://?lower-store=<cvmfs lower, read-only>&upper-layer=/nix/.rw-store/store&check-mount=false
        PATH ⟵ /cvmfs/nix.hayweb.org/profiles/<channel>/<group>/<system>/bin
```

### Why mergerfs (ADR 0002)
Nix's `local-overlay-store` targets kernel overlayfs, but overlayfs caches lower dentries/inodes and
never revalidates them; CVMFS renumbers inodes on every revision, so a publish leaves clients with
stale negatives/ESTALE until a remount that can't happen on a live host. mergerfs is a FUSE union
that re-resolves every lookup against its branches (`cache.negative_entry=0`, short `cache.entry`),
synthesises stable inodes (`inodecalc=path-hash`), and needs no remount when the RO branch changes.
Trade-offs accepted: FUSE-over-FUSE exec path; `local-overlay-store` on mergerfs is unsupported by
Nix (`check-mount=false`; Nix never deletes lower paths, so no whiteouts are needed; upper layer is a
plain dir so Nix's upper/lower checks work). Spike S2 validates `cache.files` (mmap of executables),
exec latency, and a revision flip under load. If it fails, `cvmfs_nix_mode=cache` is the fallback.

## Repo: `cvmfs-service`

Not a Python service — no `create-python-project.sh`. Keep: `CLAUDE.md`, `CONTEXT.md`,
`docs/adr/NNNN-*.md`, `prd/`, `plans/`, `flake.nix` devShell, GitHub Issues with the triage labels.

```
cvmfs-service/
  flake.nix                      # inputs: nixpkgs (Renovate), vm-service@tag, …; devShell (ansible, ansible-lint, mc, nix tools)
                                 # packages.<system>.profile-<group>   = buildEnv (profiles/<group>.nix)
                                 # apps.<system>.{publish,promote,verify-origin}
  profiles/{base,docker-host,proxmox-node,cloud,builder}.nix
  publish/publish.sh  publish/promote.sh                     # transaction/copy/symlink/publish; promote = stable→canary pointer + git commit
  server/cvmfs/{s3.conf.tmpl,server.conf.tmpl,cvmfsdirtab}
  server/nginx/cvmfs-cache.conf.tmpl
  server/minio/{bucket-policy.json,RUNBOOK.md}               # bucket, anonymous GET, publisher rw key — by hand
  ansible/roles/{cvmfs_publisher,cvmfs_nginx_cache,cvmfs_client,nix_union_store,nix_builder}
  ansible/playbooks/{publisher,cache,clients,builders}.yml   # inventory from NetBox (nb_inventory)
  secrets/*.enc.yaml                                         # SOPS/age: minio rw key, repo masterkey, nixbuild key
  docs/adr/0001-nix-over-cvmfs.md  0002-mergerfs-union-not-overlayfs.md  0003-nginx-reverse-cache-not-squid.md
  docs/runbooks/{publish-abort,resign,gc,minio-cert-cutover}.md
  CONTEXT.md  CLAUDE.md  README.md  renovate.json
```

Related changes in other repos:
- `homelab-opscontrolplane`: Caddy gets `minio.hayweb.org` (DNS-01); new stack `truenas-cert-pusher` (watches the cert, calls TrueNAS API; API key in `secrets/prod/truenas.enc.yaml`).
- `ansible-lab-config`: NetBox dynamic inventory (if not already), `requirements.yml` entry for the cvmfs-service roles, Semaphore jobs.
- `packer-service`: provisioner step in `deploy/packer-proxmox-debian13` and `-rhel10` running `cvmfs_client` + `nix_union_store` in "bake" mode (no channel/group yet).
- NetBox: tags `nix-builder`, `nix-canary`; custom fields `nix_group`, `nix_channel`; set on pi5/pi6, pi7, the canary VMs.

## Server side

**Publisher role** (`cvmfs_publisher`): `cvmfs`, `cvmfs-server`, `cvmfs-config-none`, mergerfs, Nix (Determinate, pinned);
`/etc/nix/nix.conf`: `builders = ssh://nixbuild@pi5 aarch64-linux - 4 1 ; ssh://nixbuild@pi6 …`,
`builders-use-substitutes = true`, `auto-optimise-store = false` (hardlinks don't survive CVMFS; it dedups by content).
`/etc/cvmfs/s3.conf`: `CVMFS_S3_HOST=minio.hayweb.org:<api-port>` (confirm the S3 API port — `:9002` is the console),
`CVMFS_S3_BUCKET=cvmfs`, `CVMFS_S3_USE_HTTPS=true`, `CVMFS_S3_DNS_BUCKETS=false`, keys from SOPS.
`cvmfs_server mkfs -s /etc/cvmfs/s3.conf -w http://cache1.hayweb.org/cvmfs/nix.hayweb.org nix.hayweb.org`.
`.cvmfsdirtab`: `/nix/store/*`, `/cache/*`, `/profiles/*/*`. `CVMFS_AUTOCATALOGS=false`.
Master key offline in SOPS; `cvmfs_server resign` timer every 14 days (whitelist expires at 30).
Public key `nix.hayweb.org.pub` committed and shipped by the client role.
Publish reconciler: systemd timer (5 min) → `git fetch && reset --hard origin/master` → if `flake.lock`/`profiles/` changed since last published commit → `nix run .#publish`; records the published commit in `/cvmfs/nix.hayweb.org/.published-commit`. On failure `cvmfs_server abort -f` and log to Loki.

**Promote**: `nix run .#promote -- <group>|all` → transaction; `stable/<group>/<system>` → target of `canary/…`; publish; commit `profiles/pointers.json` to master.

**MinIO runbook** (`server/minio/RUNBOOK.md`): rename to `minio.hayweb.org` (BIND CNAME → filer1; name.com DNS-01 record via Caddy), LE cert swap via pusher, Loki endpoint/cert change on pi2 in the same window, bucket `cvmfs`, policy anonymous `s3:GetObject` on `cvmfs/*`, service account with rw on `cvmfs` only. `nix run .#verify-origin` checks reachability, TLS chain, anonymous GET.

**nginx cache role** (`cvmfs_nginx_cache`):
```
proxy_cache_path /var/cache/nginx/cvmfs levels=1:2 keys_zone=cvmfs:64m max_size=100g inactive=90d use_temp_path=off;
location /cvmfs/ { proxy_pass https://minio.hayweb.org:<api-port>/cvmfs/; proxy_cache cvmfs; proxy_cache_lock on;
                   proxy_cache_use_stale error timeout updating; proxy_cache_valid 200 90d; proxy_cache_valid 404 5s; }
location ~ /\.cvmfs(published|whitelist|reflog)$ { … proxy_cache_valid 200 30s; }
```
Clients: `CVMFS_SERVER_URL=http://cache1.hayweb.org/cvmfs/@fqrn@`, `CVMFS_HTTP_PROXY=DIRECT`.

## Client side

**`cvmfs_client`**: cernvm apt/yum repo; `/etc/cvmfs/default.local` (`CVMFS_REPOSITORIES=nix.hayweb.org`,
`CVMFS_HTTP_PROXY=DIRECT`, `CVMFS_QUOTA_LIMIT` by group, `CVMFS_CACHE_BASE=/var/lib/cvmfs`);
`/etc/cvmfs/config.d/nix.hayweb.org.conf` (`CVMFS_SERVER_URL`, `CVMFS_PUBLIC_KEY`);
static fstab mount `nix.hayweb.org /cvmfs/nix.hayweb.org cvmfs defaults,_netdev 0 0` (`cvmfs_config setup nouser noautofs`).

**`nix_union_store`** (`cvmfs_nix_mode: union|cache|thin`, default `union`):
- mergerfs (Debian pkg / upstream RPM on RHEL), Nix (Determinate, pinned).
- `nix-store.mount`: `What=/nix/.rw-store/store=RW:/cvmfs/nix.hayweb.org/nix/store=RO`, `Type=fuse.mergerfs`,
  `Options=category.create=ff,inodecalc=path-hash,cache.files=auto-full,cache.negative_entry=0,cache.entry=1,allow_other,use_ino`
  (final option set from spike S2), `RequiresMountsFor=/cvmfs/nix.hayweb.org`, `Before=nix-daemon.service`.
- `/etc/nix/nix.conf`:
  `experimental-features = nix-command flakes local-overlay-store`,
  `store = local-overlay://?lower-store=local%3Froot%3D%2Fcvmfs%2Fnix.hayweb.org%26read-only%3Dtrue&upper-layer=/nix/.rw-store/store&check-mount=false`,
  `auto-optimise-store = false`, `min-free = 2G`, `max-free = 10G`. (Verify URL grammar against `nix help-stores` of the pinned version.)
- `nix-gc.timer` weekly: `nix-collect-garbage --delete-older-than 30d`.
- `/etc/profile.d/cvmfs-nix.sh`: PATH ⟵ `/cvmfs/nix.hayweb.org/profiles/{{ nix_channel }}/{{ nix_group }}/{{ system }}/bin`.
- `mode=cache`: no mergerfs; `substituters = file:///cvmfs/nix.hayweb.org/cache`; `fleet-profile.timer` (5 min) `nix copy`s the group's pointer and switches `/nix/var/nix/profiles/fleet`.
- `mode=thin`: bind mount only, no daemon.

**`nix_builder`** (pi5, pi6): Nix pinned, `nixbuild` user with the publisher's key, `trusted-users`, `max-jobs`.

## Phases

0. **Prerequisites** (issues in their own repos, linked from `cvmfs-service`):
   NetBox tags/fields + dynamic inventory in `ansible-lab-config`; MinIO rename + LE cert via Caddy + TrueNAS pusher stack (ops repo) + Loki cutover (runbook, same window); bucket/policy/key runbook.
   **Spikes** on throwaway VMs: S1 packages (`cvmfs`, `cvmfs-server`, mergerfs on Debian 13 arm64 / RHEL 10 aarch64; MinIO S3 API port); S2 mergerfs union + `local-overlay-store` (mmap/`cache.files`, exec latency, revision flip while binaries run, local build + GC); S3 `cvmfs_server mkfs` against MinIO (reflog/`.cvmfspublished` pitfalls). Write ADRs 0001–0003.
1. **Origin**: publisher VM; repo created; `profile-base` published for both systems; verified from the publisher's own client mount.
2. **Distribution**: `cache1` VM + role; `cvmfs_client` + `nix_union_store` roles; `nixcanary-deb1`, `nixcanary-rhel1`, `pi7` on `canary`; builders `pi5`/`pi6` wired; canary soak.
3. **Fleet**: packer bake step; roles via `requirements.yml`; Semaphore job; `base` promoted to `stable`; rollout by group. `vm-service` added as a flake input → `profile-docker-host`/wherever it runs; retire the curl-from-GitHub install.
4. **Cloud**: cloud hosts join (OpenVPN + pushed DNS already in place); `cloud` group.
5. **Automation & ops**: publish reconciler timer; promote flow; Renovate; resign timer; alloy ships `cvmfs_config stat` + nginx `$upstream_cache_status` to Loki/Grafana + dashboard in ops repo; runbooks (abort, resign, gc, cert cutover).

## Verification
- Origin: `cvmfs_server check nix.hayweb.org` clean; `curl -I http://cache1.hayweb.org/cvmfs/nix.hayweb.org/.cvmfspublished` → 200; `verify-origin` green.
- Client: `cvmfs_config probe` OK; `mount | grep /nix/store` is `fuse.mergerfs`; `nix store info` reports the overlay store; `ls /nix/store | wc -l` small on a fresh VM; `du -sh /var/lib/cvmfs` stays ≤ quota after exercising > quota of closures.
- On-demand + atomic update: publish a new `base`; within ~5 min `readlink /cvmfs/…/profiles/canary/base/<system>` changes on canaries and the new binary runs **without remount or restart**; `stable` hosts unchanged until `promote`.
- Revision flip under load (S2 + canary soak): a long-running process from the old profile keeps running; new lookups resolve; no ESTALE/ENOENT in `dmesg`/app logs.
- Local Nix: `nix shell nixpkgs#hello -c hello`; path lands in `/nix/.rw-store/store`; `nix-collect-garbage -d` removes it and nothing from CVMFS.
- Cache: second host fetching the same closure logs `HIT` on cache1; cloud host over OpenVPN resolves `cache1.hayweb.org` internally and probes OK.
- Both arches/OSes: all checks on pi7 (aarch64 Debian), `nixcanary-deb1`, `nixcanary-rhel1`.
- Fallback: flip one canary to `cvmfs_nix_mode=cache`; `fleet-profile.timer` installs the group profile from `file:///cvmfs/…/cache`.
