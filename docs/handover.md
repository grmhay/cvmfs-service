# Handover

State of the work as of **2026-10-30**. Design: `plans/0001-nix-over-cvmfs.md`; vocabulary: `CONTEXT.md`.
The work left is the spec #23 (phases 2–5, from the canaries to the whole fleet) and its tickets #24–#34.

Phases 0 and 1 are done. The Repository `nix.hayweb.org` is live: the Publisher's reconciler publishes every
Group's Profile to `canary` for both systems, the Cache serves it, and the whitelist re-signs itself weekly
(#19, collection `v0.5.0`, which ansible-lab-config now pins). **No host outside the Publisher reads the
Repository yet.** The three Canary hosts still run their Union Store over the stand-in Lower Store.

**Since the Publisher's reboot at 10:41 on 2026-10-30, its own Union Store is down** (see the first row of
the table). Publishing has not been affected so far only because nothing has changed on `master` since
`dd9e3c1`.

## Live state (read over SSH on 2026-10-30, 11:29–11:35 MST)

Read as `ansible` over SSH with `BatchMode` (FQDNs only; short names fail host-key checks). Nothing was
changed on any host. A row marked **unverified** could not be read today; its source is named.

| Item | State on 2026-10-30 |
|---|---|
| Publisher: Union Store | **Down since the 10-30 10:41 reboot.** `systemd` found an ordering cycle (`local-fs.target` → `nix-store.mount` → `cvmfs\x2dclient-nix.hayweb.org.mount` → `network-online.target` → … → `local-fs.target`) and deleted the `nix-store.mount` start job. `/nix/store` is not mounted, so `nix-daemon.service` (a symlink into the profile under `/nix`) "could not be found". The client mount `/cvmfs-client/nix.hayweb.org` is up. Needs a ticket: the mount unit must not sit in `local-fs.target` while it needs a network mount. Not fixed here |
| Publisher: repository mount | `cvmfs_server list` says `nix.hayweb.org (stratum0 / S3 - gw/mountless)`; `/cvmfs/nix.hayweb.org` is an empty directory after the reboot. Whether the next real Publish remounts it on its own is **unverified** |
| Publisher: size | Configured as 4 vCPU / 12 GB (operator, 2026-10-30). The guest sees 4 vCPUs but `MemTotal` 8 138 012 kB (7.8 GiB) after the 10:41 reboot. Check the VM's memory and balloon settings in Proxmox before reading a recurring OOM as "12 GB is not enough" (#26) |
| Publisher: timers | `cvmfs-publish.timer` every ~5 min; every run since 10-28 02:46 says `already published dd9e3c1c7940; nothing to do`. `cvmfs-resign.timer` next fires Mon 2026-11-02 03:00; it has not run since the reboot |
| Publisher: last Publishes | 2026-10-27 18:34 `successfully published revision 3` (commit 084d1eb, then the first Promote of `builder`, 18:39); 2026-10-27 19:46 re-pointed all five `canary` Groups (dd9e3c1) |
| Publisher: failures | 10-26 20:59 and 10-27 10:17 `exit-code`; **10-27 10:33 `oom-kill`**; **10-28 02:43 `exit-code`, the git fetch from github.com timed out**. In the 10-27 OOM the kernel log names only `(sd-pam)` of uid 1003 and `telegraf` (10:32:08, 10:32:12) as victims; the process killed inside `cvmfs-publish.service` is not in the journal. Diagnosis and the fetch retry are #26 |
| Channels | `canary`: `base`, `builder`, `cloud`, `docker-host`, `proxmox-node`, each for `aarch64-linux` and `x86_64-linux` (all re-pointed 10-27 19:46). `stable`: only `builder`, both systems (10-27 18:39, same store paths as `canary/builder`). There is no `stable/base` |
| Cache (`cache1`) | nginx active; `HEAD /cvmfs/nix.hayweb.org/.cvmfspublished` → 200, `X-Cache-Status: HIT`, `Last-Modified: Wed, 28 Oct 2026 02:46:35 GMT`. Access logs since 10-26: 3008 EXPIRED, **984 HIT**, 76 MISS; HITs include data objects (`/data/28/92550d…C` for both 192.168.50.5 and the Publisher). Cache directory 1.5 MB |
| Cache clients | 192.168.20.118 (Publisher, 1326 requests), 192.168.50.5 (1377), 192.168.50.6 (1356), plus a few from this workstation and 192.168.70.3. .50.5/.50.6 are probably the Builders pi5/pi6 (no PTR; **unverified**, `ansible@pi5`/`pi6` refuses the key). No Canary host's address appears |
| Canary hosts | `pi7` (Debian 13 aarch64), `nixcanary-deb1` (Debian 13 x86_64), `nixcanary-rhel1` (RHEL 10.2 x86_64): all `nix (Nix) 2.30.0+chrootfix`, `/nix/store` is `nixstore fuse.mergerfs`, and the nix-daemon drop-in's `lower-store` is the stand-in `/srv/lower`. `nix config show` on nixcanary-deb1: `sandbox = true`, `sandbox-fallback = true` (pi7 and rhel1 read the same on 10-28; not re-read today) |
| Canary Repository mount | None of the three mounts the Repository. pi7 has the cvmfs packages but no `nix.hayweb.org` config and an empty `/cvmfs`; nixcanary-deb1 and nixcanary-rhel1 have no cvmfs package and no `/cvmfs` |
| Canary PATH | `/etc/profile.d/cvmfs-nix.sh` on all three says `channel=stable group=base` and points at `/cvmfs/nix.hayweb.org/profiles/stable/base/<system>/bin`, which exists on no host. NetBox's seed data (`nix_hosts` in ansible-lab-config's bootstrap-netbox `vars/devices.yml`) gives them `canary`. Why the role wrote `stable` is #28's first question |
| Canary sandbox settings | `nix_union_sandbox`/`nix_sandbox_fork` are still not in ansible-lab-config's group vars for `tag_nix_canary` (ansible-lab-config#122, open), so a `cvmfs: clients (canaries)` run would turn their sandbox off. Read from a 10-28 clone of ansible-lab-config |
| Builders `pi5`, `pi6` | **Unverified**: SSH as `ansible` refuses the key. The Cache's logs suggest they fetch from the Repository |
| Whitelist | Resigned unattended by `cvmfs-resign.service` (#19). The expiry alert (#20, homelab-opscontrolplane half) is not live |
| Renovate | Not running: `renovate.json` exists, but no Renovate PR, onboarding PR or Dependency Dashboard on any grmhay repo (10-28). #25 |
| vm-service curl install | Never existed as automation: the only `curl` is vm-service's README. No `vm_service` binary on the Publisher, the Cache or the canaries (10-28). The service itself runs as a container on skyline |
| First boot of new VMs | packer-service runs no Ansible; vm-service's post-create chain triggers Semaphore "Buildhost All", then "Verify Host". Nothing in that chain installs CVMFS or Nix (10-28) |
| Cloud host `pinger` | **Unverified**: `pinger.hayweb.org` does not resolve from here and `pinger` is in neither ansible-lab-config inventory. Debian 12, x86_64 per #23. #27 |

Finished and closed: S1–S3 (#1–#3, `docs/spikes/`), the four long-lived VMs (#5), the Publisher's first-run
fixes (#15–#17), secrets under Semaphore (#18), the chroot-fix fork on the canaries (#14,
`docs/canary-nix-fork.md`) and the unattended resign (#19). Open by choice: #4 waits for `verify-origin` from
a cloud host (now #27). #6, #9 and #13 wait on a Nix release with the chroot-parent fix.

## Next: spec #23

The order and the gates are in the plan (`plans/0001-nix-over-cvmfs.md`, "Amendments 2026-10-30"). In short:
#26 (Publishes survive transient failures) and #28 (Canary hosts read the Repository) come first; then the
Soak (#29); then, before any non-canary host moves, the whitelist alert (#20), every host's Group in NetBox
(#30) and a client-roles Semaphore template with a host limit; then the Rollouts #31–#34. #21 (vm-service in
`docker-host`) and #25 (Renovate) are independent; #21 gates the `docker-host` Rollout.

## Draft: Group per host

The input to #30, for the operator to correct. The host list is ansible-lab-config's static `inventory` plus
the `nix_hosts` and `virtual_machines` of its bootstrap-netbox seed (`vars/devices.yml`), from a 10-28 clone.
**Live NetBox could not be read** (no token here), so any VM vm-service created that is not listed below is
missing; check NetBox's virtual machines for more before entering these. "OS/arch" is what SSH showed today
where it says *live*; otherwise it is the seed's platform, which is stale for some hosts (pi7's says Bookworm;
it runs Debian 13). "NetBox now" is the seed's `nix_group`/`nix_channel`; *default* means no custom field,
which the inventory reads as `base`/`stable`.

| Host | OS/arch | NetBox now | Draft Group | Notes |
|---|---|---|---|---|
| `publisher` | Debian 13 x86_64 (live) | builder/canary | `builder` | The Publisher |
| `pi5` | RPi OS Bookworm, aarch64? | builder/stable | `builder` | Builder; also in `[portainer]`. Arch **unverified** (SSH refused) |
| `pi6` | RPi OS Bookworm, aarch64? | builder/stable | `builder` | Builder |
| `cache1` | Debian 13 x86_64 (live) | default (role `nix_cache`) | `base` | Not a client today: `clients.yml` excludes `nix_cache`. Set `base` explicitly anyway |
| `pi7` | Debian 13 aarch64 (live) | base/canary | `base` | Canary host |
| `nixcanary-deb1` | Debian 13 x86_64 (live) | base/canary | `base` | Canary host |
| `nixcanary-rhel1` | RHEL 10.2 x86_64 (live) | base/canary | `base` | Canary host; needs root over SSH |
| `pi1` | RPi OS Bookworm | default | `base` | The Ansible controller (`ansible`) |
| `pi3` | RPi OS Bookworm | default | `base` | |
| `pi4` | RPi OS Bookworm | default | `base` | `pidnsdev` |
| `pi12` | RPi OS Bookworm | default | `base` | |
| `pijump1` | RPi OS Bookworm | default | `base` | Jump host |
| `pijump2` | RPi OS Bookworm | default | `base` | Jump host |
| `pi17` | RPi OS Bookworm | default | `base` | `pidns1`, DNS server; commented out of `[raspian]` |
| `pi18` | RPi OS Bookworm | default | `base` | `pidns2`, DNS server; commented out of `[raspian]` |
| `unifi` | Debian 12 | default | `base` | |
| `netbox1` | Debian 12 (VM) | default | `base` | |
| `netbox2` | Debian 12 (VM) | default | `base` | |
| `dhcp1` | Debian 12 (VM) | default | `base` | |
| `dhcp2` | Debian 12 (VM) | default | `base` | |
| `dhcptest` | Debian 12 (VM) | default | `base` | |
| `claudecourse` | Debian 12 (VM) | default | `base` | Has distro `nix-bin` 2.26.3; migrated in the `base` Rollout (#31) |
| `skyline` | Debian 13 x86_64 (live) | default | `docker-host` | Runs vm-service, Caddy and the ops stacks (seed says Debian 12) |
| `librenms` | Debian 12 | default | `docker-host` | In `[portainer]` |
| `pi2` | RPi OS Bookworm | default | `docker-host` | In `[portainer]`; hosts Loki |
| `pi9` | RPi OS Bookworm | default | `docker-host` | In `[portainer]` |
| `labserver5` | Proxmox VE 8 | default | `proxmox-node` | Saddlehorn; first wave of its Rollout. SSH timed out today |
| `labserver6` | Proxmox VE 8 | default | `proxmox-node` | Saddlehorn; first wave. SSH timed out today |
| `labserver7` | Proxmox VE 8 | default | `proxmox-node` | Saddlehorn; first wave. SSH timed out today |
| `labservera` | Proxmox VE 9 | default | `proxmox-node` | Saddlehorn2 |
| `labserverb` | Proxmox VE 9 | default | `proxmox-node` | Saddlehorn2 |
| `labserverc` | Proxmox VE 9 | default | `proxmox-node` | Saddlehorn2 |
| `labserverd` | Proxmox VE 9 | default | `proxmox-node` | Saddlehorn2 |
| `labserverw1` | Proxmox VE 9 | default | `proxmox-node` | Standalone node |
| `proxmoxbackup1` | Proxmox VE 8 / PBS | default | `proxmox-node` | Backup server |
| `labserver3` | Proxmox VE 8 | — | none | Being decommissioned (`status: decommissioning`, out of the inventory). Excluded from every Rollout |
| `labserver4` | Proxmox VE 8 | — | none | Being decommissioned (`status: decommissioning`, out of the inventory). Excluded from every Rollout |
| `pinger` | Debian 12 x86_64 (Google Cloud) | not in NetBox | `cloud` (`stable`) | Upgraded to Debian 13 first (#27) |
| `filer1` | TrueNAS SCALE | not in nb_inventory | none | Hosts the Origin; static `[truenas]` only |

Not Ansible targets, so no Group: switches, APs, routers (`phoenixwan0`, `phoenix2`), UPSs and the ATS, which
nb_inventory filters out by role.

Open questions for #30 and #31:

- **Debian 12 and Raspberry Pi OS Bookworm.** The supported clients are Debian 13 and RHEL 10, and #23 does
  not add Debian 12. By the seed's platforms most of `base` and `docker-host` is Bookworm. Which of them are
  really on 13 today is **unverified**: SSH as `ansible` refused the key on every host except the Publisher,
  the Cache, the canaries and skyline. Each Group's Rollout needs its hosts on a supported OS first, or an
  explicit decision.
- The Pis' architecture: Raspberry Pi OS can be 32-bit. Only pi7 is confirmed aarch64.
- pi5 is both a Builder and a docker host; its Group stays `builder` here.

## Triage conventions

- Labels: one category (`enhancement` / `bug`) and one state per issue (`docs/agents/triage-labels.md`).
- **`blocked`** is a flag next to the state label, not a state: the issue waits on something outside this repo,
  named in its body or latest comment. Agents skip `ready-for-agent` issues that carry it. Remove it when the
  blocker clears; no re-triage needed. Today it is on #6 and #13 (both wait on a Nix release with the #9 fix).
- Comments posted during triage start with `> *This was generated by AI during triage.*`

## Template repo (grmhay/pythonproject)

The `blocked` flag is standard in the template: #28 added it, and #29 (merged 2026-10-19) fixed its review
findings. The Sandbox Loop filters `blocked` on GitHub's side, the glossary defines the Blocked flag, and
`create-python-project.sh` offers to create the five triage labels plus `blocked` on a new repo. Existing
projects get the loop and the triage labels doc on `copier update`; their `CLAUDE.md`, `CONTEXT.md` and
`README.md` are project-owned and stay as they are.

## Working notes

- **Ansible collection:** since `v0.1.0` (83734c8), `ansible/` installs as the collection `grmhay.cvmfs_service`
  from the git subdirectory. Its roles are `grmhay.cvmfs_service.<role>`, and its playbooks run as
  `grmhay.cvmfs_service.publisher`, `cache`, `builders` and `clients`. Consumers pin it by tag, so a role change
  they need means a new tag.

- **vm-service:** `--prefix 192.168.20.0/24` lets it pick a clean address from NetBox's reservable range; there
  is no NetBox token in this environment for looking one up. `get-job` does not print config/verify state:
  `GET $VM_SERVICE_URL/jobs/<id>` with the `.env` `API_TOKEN` does. Changes land on vm-service `main` through
  merged PRs, not direct pushes. Until vm-service#209's fix (PR #210, merged 2026-10-19) is deployed, new VMs
  get a short FQDN (`hostname -f` without `hayweb.org`); 103, 109, 111 and 112 keep it until re-created or patched. Its first-boot Ansible run keeps going after
  `create-vm` returns, so wait for it before using apt. A re-created VM keeps its name, so remove the stale
  `known_hosts` entry. Confirm a VMID with `get-vm` before `destroy-vm`.
- **Auto mode** blocked these until the user explicitly asked for them: `vm_service create-vm`, uploads to the
  real bucket, `gh pr create`, `gh pr merge`, and editing an issue comment. Ask, or have the user add permission
  rules.
- **mkfs** needs an empty bucket, and the Cache must not hold copies from an earlier attempt. `-w` is the bucket,
  never the Cache.

## Standing rules

- VMs come from vm-service, created by the agent; throwaway ones are destroyed afterwards.
- MinIO buckets, policies and keys are made **by hand** by the user; scripts only prepare the commands.
- When handing the user commands, put `nix develop` and any `mc` command that prompts for the MinIO admin password
  (`mc alias set …`) in their own block, then the rest after a break. A pasted block loses the rest to the new
  shell or the password prompt. `server/minio/RUNBOOK.md` §2 shows the layout.
- Only `*.enc.yaml` is committed (age recipient shared with homelab-opscontrolplane). Never print secret values.
- Confirm before outward-facing actions (issues, PRs, pushes) unless asked.

## Other loose ends

- grmhay/packer-service#111 (needs-triage): raise the Debian 13 and RHEL 10 templates' default root disk to
  100G (amended from 60G on 2026-10-20), so Nix hosts built from them don't fill `/`. Every VM from those
  templates is then at least 100G; vm-service `--disk` only grows.

- pidns1 and pidns2 report different `hayweb.org` SOA serials: seen 2026-10-16, still different on 2026-10-19
  (1771979346 on 192.168.40.17, 1771807930 on 192.168.50.17). Not investigated.
- homelab-opscontrolplane: optional truenas-cert-pusher change to log the "waiting for certificate" state at INFO
  without backoff (offered, not filed).
