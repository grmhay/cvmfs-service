# Handover

State of the work as of **2026-11-05**. Design: `plans/0001-nix-over-cvmfs.md`; vocabulary: `CONTEXT.md`.
The work left is the spec #23 (phases 2–5, from the canaries to the whole fleet) and its tickets #24–#34.

Phases 0 and 1 are done. The Repository `nix.hayweb.org` is live: the Publisher's reconciler publishes every
Group's Profile to `canary` for both systems, the Cache serves it, and the whitelist re-signs itself weekly
(#19). **Since the evening of 2026-10-30 the three Canary hosts read it too**, on `canary`, with the build
sandbox on, and **the Soak (#29) has started**: earliest sign-off 2026-11-06.

The repo side of #23 is merged (#36, then the fixes #39, #41, #52 and #53) and released as collection
`v0.6.4` (e4ab9cb), which ansible-lab-config pins (its bc6393aa). #28, #35, #37, #41, #42 and #44 are closed; #26 waits
on Publishes. The fleet came back cleanly from the reboots of 2026-11-01. The weekly GC, which had never
finished anywhere, was fixed on 2026-11-03 (#42). Since revision 8 (2026-11-04) the Lower Store is one nested
catalog at `/nix` (#44, ADR 0006), and published paths pass `nix store verify`. Revision 9 (the nixpkgs
bump #49) is the Soak's first counted Publish, and the revision-flip criterion passed on it. GC now finishes on
every union host but logs `BUG:` lines (#50). On 2026-11-05 every manual Soak criterion passed, the last
being one canary to cache Mode and back, with no hand repair, on `v0.6.4`. See "Since 2026-10-30" below.

## Since 2026-10-30 (to 2026-11-05)

From Semaphore task logs and ad-hoc Ansible runs by the operator on the hosts. Ad-hoc commands run as
`ansible` on pi5 from `/etc/ansible-lab-config`, with `-i nb_inventory.yml --vault-password-file=vault/vault_pass.txt`;
the Publisher login is `pi` (sudo asks for a password). Under `sudo` and Ansible's shell, `nix` is not on
PATH: use `/nix/var/nix/profiles/default/bin/nix`. Where this section and the two below differ, this one is newer; #37's
`vm_service` check passed on revision 6 (both systems).

| Item | State on 2026-11-05 |
|---|---|
| Collection | `v0.6.4` pinned in ansible-lab-config (bc6393aa, its #154). `v0.6.3` (#52): leaving union Mode for cache Mode fetches every missing store path (`files/fill-missing-paths.sh`; `nix-store --verify --repair` does not), returning to union removes cache Mode's puller and `fleet` profile, and the client reloads cvmfs whenever the live quota differs from NetBox's. `v0.6.4` (#53): the puller's timer gets a first pull (`OnActiveSec`). ansible-lab-config's #152 sets `force_handlers` on the clients wrapper. #54 (open) only stops the fill task from always reporting changed |
| Agent access | The agent can SSH as `ansible@` to the canaries, pi5 and pi6 (NOPASSWD sudo), not to the NetBox hosts. It drives Semaphore through its API (`~/.config/semaphore/token`) and NetBox through its API (`~/.config/netbox/token`, with NetBox's self-signed certificate pinned as `~/.config/netbox/netbox.crt`; fingerprint confirmed by the operator on netbox1). It asks before every template launch and every NetBox write, and journals each NetBox change on the object |
| nixbuild key | Rotated (#41; the old private key had been exposed in an agent session). New key `SHA256:VM9tUJC5pdsqyAApLQ0yRgI/Gt1L7Ufk/WTqmS304kY` in `publisher.enc.yaml`; `cvmfs: publisher` task 245, then `cvmfs: builders` task 246 (authorised the new key, revoked the old one on pi5 and pi6). Verified 11-03: on the Publisher, `sudo /nix/var/nix/profiles/default/bin/nix store info --store ssh://nixbuild@pi5` (and `@pi6`) answers with no password prompt. Use the short names: root's `/root/.ssh/config` matches `Host pi5`/`pi6` only, so an FQDN offers the wrong key and falls back to a password |
| Reboots of 2026-11-01 | The Publisher, pi6, pi7, nixcanary-deb1 and nixcanary-rhel1 booted at about 01:00. On each: `/nix/store` on `fuse.mergerfs`, `nix-daemon.socket` active, no ordering cycle in `journalctl -b` (#35 holds unattended). pi5 (up since 10-25) and cache1 (since 10-30 12:52) did not reboot; whether they should have is **unverified**. `systemctl is-system-running` was `degraded` only because of `nix-gc.service` |
| Weekly GC (#42) | Failed on all six union hosts on 11-01: `error: deleting '/nix/store/.links/.cvmfscatalog': Read-only file system`. The dirtab's `/nix/store/*` had put a catalog marker in the Lower Store's `.links`. #43 (0756dde) excludes `.links` and removes the marker in the transaction; a publish run by hand on 11-03 applied it. GC then finished on the Publisher (RW Branch 309M → 146M) and the three canaries (unchanged). The docker-host Profile stayed `VALID` with all 142 paths. On 11-04 the agent started `nix-gc.service` on pi5 and pi6, on revision 8 and again on revision 9: `Result=success` all four times, both back to `running` |
| GC counts | Every GC reports hundreds to thousands of paths "deleted" and an absurd "MiB freed" (up to ~44 PiB). The overlay store's GC drops published paths from the local database and counts their sizes; their files stay. Harmless so far. On pi5 and pi6 every run also logs 80–126 `BUG: error: cannot delete path … because it is in use by …` lines; in the pair checked, both paths are in the Lower Store. **#50** (needs triage): is it upstream, do the canaries log it too, and does it leave RW-Branch paths uncollected? |
| Catalog layout (#44, closed) | The old dirtab's `/nix/store/*` had put a `.cvmfscatalog` in **every** published store path, so `nix store verify --no-trust` failed on all of them. #46 (4cfb80d) roots one catalog at `/nix` (ADR 0006; not `/nix/store`, whose non-path entries GC deletes) and `publish/drop-path-catalogs.sh` removed the old markers. The reconciler published it as **revision 8** at 05:03:34 on 11-04: `cvmfs_server check` no problems, 11 catalogs and none under `/nix/store`. On the Publisher, pi7 and nixcanary-deb1 the docker-host closure (142 paths) verifies, copies to an empty store, and survives a GC. Every new revision now refetches the whole `/nix` catalog (about 65k entries, an estimated 8–10 MB); nothing monitors its size yet |
| Publishes | #43 touches no publish input (`flake.nix`, `flake.lock`, `profiles/`), so the reconciler records it without publishing. The 11-03 publish was run by hand as `publisher`: `git reset --hard origin/master`, then `nix run .#publish` (its revision number is not recorded here). To run one by hand, hold the reconciler's lock, `flock ~/.local/state/cvmfs-publish/publish.lock nix run .#publish` (`publisher_lock_file`), **not** `/tmp/cvmfs-publish.lock`: on 11-04 a run under that wrong lock collided with the reconciler's publish of #46 (revision 8, the `/nix` catalog of ADR 0006); its `cvmfs_server transaction` failed and nothing was harmed. The agent can also SSH to the fleet itself as `ansible@<host>.hayweb.org` (NOPASSWD sudo; `sudo -u publisher` for the repository owner): the Publisher, pi5 and pi6 (key added 11-04), and the three canaries |
| nixpkgs bump (#49) | nixpkgs 2026-10-08 → 2026-11-03 (82cf4e5); base Profile `wjw1yr16…` → `kcz522m5…` on x86_64, `f1sfw46…` → `hilx4zma…` on aarch64. The reconciler published it as **revision 9** at 08:12 on 11-04 in 4 minutes: `cvmfs_server check` no problems, none of the catalogs under `/nix/store`. The aarch64 outputs came from cache.nixos.org, so pi5 and pi6 did no real build (no OOM, and no load either: #26 is still unexercised). The devShell permits `minio-client-2025-08-13T08-35-41Z`, which nixpkgs now marks insecure (abandoned upstream); a bump that changes its version fails `nix develop` again. Replacing `mc` is undecided |
| Soak (#29) | **Every manual criterion passes**; what is left is Publishes and the sign-off. **Publishes: 1 of 3** (revision 9) if only Profile-changing Publishes count, 3 if 7 and 8 count: the operator's call. **Revision flip under load: passes** on all three canaries (~450 `jq` runs, 0 failed, no ESTALE). The `tmux -L soakflip` loops still run on rhel1 and pi7; deb1's was stopped for the round trip (log `~ansible/soak-flip.log.rev9`) and not restarted. **Local build plus GC: passes**: `hello` lands in the RW Branch only, and GC leaves the Lower Store and the base Profile alone. **Cache within quota: passes**: deb1 at 1000 MB read 1600 MB, the cache peaked at 928 MB and ended at 637 MB, NOIOERR 0. **cache Mode round trip: passes** on `v0.6.4`, set in NetBox and run through "cvmfs: clients (canaries)": to cache (task 251, then task 252 after #53), and back to union (task 253) with 0 missing paths, `nix-store --verify` clean and the quota back at 20000 MB. The first trip (tasks 248–250, 0.6.2) needed a hand repair, which #52 removed. Not yet shown: a Profile-changing Publish reaching a cache-Mode host by itself. The flake-registry row and `/srv/lower` are gone from all canaries (11-04). Evidence: comments on #29 |
| Resign | Mon 2026-11-02 03:00:01: `whitelist re-signed`, the service and its cleanup both exit 0, and no master key is left on disk. The Cache serves a `.cvmfswhitelist` signed 2026-11-02 10:00 UTC, expiring 2026-12-02 10:00 UTC. Next run Mon 2026-11-09 03:00 |

## Since the morning (2026-10-30, afternoon)

From the Semaphore task logs and the operator's own checks on the hosts, not from an SSH read like the
table below. These rows supersede that table's Publisher Union Store and Canary rows.

| Item | State on the evening of 2026-10-30 |
|---|---|
| Collection | `v0.6.1` pinned in ansible-lab-config. `cvmfs: publisher` task 241 ran `v0.6.0`; `cvmfs: clients (canaries)` tasks 243 and 244 ran `v0.6.1`, green on all three canaries |
| Publisher: daemon | Tasks 236, 238 and 239 failed with nix-daemon and its socket down (`Unit nix-daemon.socket not found`: the units were links into a `/nix/store` that a boot had left unmounted). The operator ran `systemctl daemon-reload` and started the socket by hand; task 240 (`v0.5.0`) then passed. 74713eb stops a daemon that does not answer from failing the version check |
| Publisher: Union Store | Task 241 replaced the daemon's units with plain files and the mount unit with a network mount. Boots at 14:53:44 and 14:57:18: no "ordering cycle" in `sudo journalctl -b`, `/nix/store` on `fuse.mergerfs`, `nix-daemon.socket` active. **#35 closed** |
| Publisher: Publishes | `successfully published revision 6` at 14:03, the first since task 241 wrote the vm-service token. Whether it built `profile-docker-host` with `vm_service` is **unverified** (#37: check `~publisher/.local/state/cvmfs-publish/published` and `profiles/canary/docker-host/*/bin/vm_service`) |
| vm-service access | Private repo. CI reads it with the `VM_SERVICE_TOKEN` secret; the Publisher with `github_access_token` from `publisher.enc.yaml`, written to `/home/publisher/.config/nix/nix.conf` (0600). The token has an expiry: when it lapses, CI and the publish fail with a 404 |
| Canary hosts | All three on the Repository's Lower Store through the Cache (pi7 from task 242, nixcanary-deb1 and nixcanary-rhel1 from 243), PATH on `profiles/canary/base/<system>`, daemon units as files. nixcanary-deb1's boot had left its union unmounted, which #39 handles. nixcanary-rhel1 boot at 14:50:13 clean. **#28 closed** |
| Canary sandbox | `buildhost-all/group_vars/tag_nix_canary.yml` in ansible-lab-config (#122, closed). Task 244: the gate accepted `2.30.0+chrootfix` on all three and the sandboxed smoke build passed. Tasks 242–243 had rewritten `nix.conf` with the role default (sandbox off) in between |
| nixcanary-rhel1 sudo | `ansible` had lost NOPASSWD: RedHat's `sudoers.d/wheel` from `add_adminuser` overrides it. Fixed by hand; the role fix is ansible-lab-config#126 (open) |
| Soak (#29) | Started after task 244; comment on #29. Earliest sign-off 2026-11-06. Publishes count from the first after task 244 |

## Live state (read over SSH on 2026-10-30, 11:29–11:35 MST)

Read as `ansible` over SSH with `BatchMode` (FQDNs only; short names fail host-key checks). Nothing was
changed on any host. A row marked **unverified** could not be read today; its source is named. The
Publisher Union Store and Canary rows are superseded by "Since the morning" above.

| Item | State on 2026-10-30 |
|---|---|
| Publisher: Union Store | **Down since the 10-30 10:41 reboot.** `systemd` found an ordering cycle (`local-fs.target` → `nix-store.mount` → `cvmfs\x2dclient-nix.hayweb.org.mount` → `network-online.target` → … → `local-fs.target`) and deleted the `nix-store.mount` start job. `/nix/store` is not mounted, so `nix-daemon.service` (a symlink into the profile under `/nix`) "could not be found". The client mount `/cvmfs-client/nix.hayweb.org` is up. #35's boot-order test, `tests/union-mount-order.sh`, runs only by hand under `nix develop` on a Debian 13 workstation (systemd 257): nixpkgs' systemd 262 does not reproduce the cycle, so it is not a flake check |
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
| Renovate | Not running: `renovate.json` exists, but no Renovate PR, onboarding PR or Dependency Dashboard on any grmhay repo (10-28). #25. Once it runs, a tag bump of a `grmhay/*` service input (the `customManagers` entry, #21) edits `flake.nix` only: run `nix flake update <input>` on the PR's branch and push `flake.lock` to the PR before merging it |
| vm-service curl install | Never existed as automation: the only `curl` is vm-service's README. No `vm_service` binary on the Publisher, the Cache or the canaries (10-28). The service itself runs as a container on skyline |
| First boot of new VMs | packer-service runs no Ansible; vm-service's post-create chain triggers Semaphore "Buildhost All", then "Verify Host". Nothing in that chain installs CVMFS or Nix (10-28) |
| Cloud host `pinger` | **Unverified**: `pinger.hayweb.org` does not resolve from here and `pinger` is in neither ansible-lab-config inventory. Debian 12, x86_64 per #23. #27 |

Finished and closed: S1–S3 (#1–#3, `docs/spikes/`), the four long-lived VMs (#5), the Publisher's first-run
fixes (#15–#17), secrets under Semaphore (#18), the chroot-fix fork on the canaries (#14,
`docs/canary-nix-fork.md`), the unattended resign (#19), and from #23: #21, #24, #28, #35, #37, #41, #42, #44. Open by choice: #4 waits for `verify-origin` from
a cloud host (now #27). #6, #9 and #13 wait on a Nix release with the chroot-parent fix.

## Next: spec #23

The order and the gates are in the plan (`plans/0001-nix-over-cvmfs.md`, "Amendments 2026-10-30"). In short:
#28 is done and the Soak (#29) is running: its manual criteria (a revision flip under load, the cache at or
under quota, a local build and GC that leave the Lower Store alone, one canary to cache Mode and back) are
the work of the week. #26 closes once Publishes go through, and those Publishes count toward the Soak's
three. Then, before any non-canary host moves, the whitelist alert (#20), every host's Group in NetBox
(#30) and a client-roles Semaphore template with a host limit; then the Rollouts #31–#34. #21 (vm-service in
`docker-host`, done in `v0.6.0`) and #25 (Renovate) are independent; #21 gates the `docker-host` Rollout.
When Renovate is enabled, give its app access to grmhay/vm-service too, or it cannot see the tags.

## Draft: Group per host

The input to #30, for the operator to correct. **Refreshed from live NetBox on 2026-11-05**: every
`status: active` device the inventory targets (`nb_inventory.yml` filters out switches, APs, routers, UPSs
and the ATS) and every active VM. No VM has appeared since the 10-28 draft. "OS/arch" is *live* where SSH as
`ansible@` answered. Elsewhere it is NetBox's platform, which is **stale** wherever it could be checked: it says
Bookworm for pi5, pi6 and pi7 and Debian 12 for skyline, and all four run Debian 13. Of the 35 hosts, 8
answered; 24 refuse the agent's key and labserver5–7 time out. A fact gather from pi5's controller would fill the column
in one run (see the questions below). "NetBox now" is the live `nix_group`/`nix_channel`. *Unset* means
no custom field, which the inventory reads as `base`/`stable`. `nix_group` is a select field (base,
docker-host, proxmox-node, cloud, builder) on devices and VMs.

| Host | Kind | OS/arch | NetBox now | Draft Group | Notes |
|---|---|---|---|---|---|
| `publisher` | VM | Debian 13 x86_64 (live) | builder/canary | `builder` | The Publisher. No NetBox platform |
| `pi5` | device | Debian 13 aarch64 (live) | builder/stable | `builder` | Builder; also a docker host (`[portainer]`) |
| `pi6` | device | Debian 13 aarch64 (live) | builder/stable | `builder` | Builder |
| `cache1` | VM | Debian 13 x86_64 (live) | unset (role `nix_cache`) | `base` | Not a client: `clients.yml` excludes `nix_cache`. Set `base` explicitly anyway |
| `pi7` | device | Debian 13 aarch64 (live) | base/canary | `base` | Canary host |
| `nixcanary-deb1` | VM | Debian 13 x86_64 (live) | base/canary | `base` | Canary host |
| `nixcanary-rhel1` | VM | RHEL 10.2 x86_64 (live) | base/canary | `base` | Canary host |
| `pi1` | device | RPi OS Bookworm | unset | `base` | The Ansible controller |
| `pi3` | device | RPi OS Bookworm | unset | `base` | |
| `pi4` | device | RPi OS Bookworm | unset | `base` | `pidnsdev` |
| `pi12` | device | RPi OS Bookworm | unset | `base` | |
| `pijump1` | device | RPi OS Bookworm | unset | `base` | Jump host |
| `pijump2` | device | RPi OS Bookworm | unset | `base` | Jump host |
| `pi17` | device | RPi OS Bookworm | unset | `base` | `pidns1`, DNS server |
| `pi18` | device | RPi OS Bookworm | unset | `base` | `pidns2`, DNS server |
| `unifi` | device | Debian 12 | unset | `base` | |
| `netbox1` | VM | Debian 12 | unset | `base` | |
| `netbox2` | VM | Debian 12 | unset | `base` | |
| `dhcp1` | VM | Debian 12 | unset | `base` | |
| `dhcp2` | VM | Debian 12 | unset | `base` | |
| `dhcptest` | VM | Debian 12 | unset | `base` | |
| `claudecourse` | VM | Debian 12 | unset | `base` | Distro `nix-bin` 2.26.3; migrated in the `base` Rollout (#31) |
| `skyline` | device | Debian 13 x86_64 (live) | unset | `docker-host` | vm-service, Caddy and the ops stacks |
| `librenms` | device | Debian 12 | unset | `docker-host` | `[portainer]`; NetBox role `monitoring` |
| `pi2` | device | RPi OS Bookworm | unset | `docker-host` | `[portainer]`; Loki |
| `pi9` | device | RPi OS Bookworm | unset | `docker-host` | `[portainer]` |
| `labserver5` | device | Proxmox VE 9 (NetBox) | unset | `proxmox-node` | Saddlehorn; first wave of its Rollout |
| `labserver6` | device | Proxmox VE 9 (NetBox) | unset | `proxmox-node` | Saddlehorn; first wave |
| `labserver7` | device | Proxmox VE 9 (NetBox) | unset | `proxmox-node` | Saddlehorn; first wave |
| `labservera` | device | Proxmox VE 9 | unset | `proxmox-node` | Saddlehorn2 |
| `labserverb` | device | Proxmox VE 9 | unset | `proxmox-node` | Saddlehorn2 |
| `labserverc` | device | Proxmox VE 9 | unset | `proxmox-node` | Saddlehorn2 |
| `labserverd` | device | Proxmox VE 9 | unset | `proxmox-node` | Saddlehorn2 |
| `labserverw1` | device | Proxmox VE 9 | unset | `proxmox-node` | Standalone node |
| `proxmoxbackup1` | device | Proxmox VE 8 / PBS | unset | `proxmox-node` | Backup server; NetBox role `storage` |

Not in the inventory, so no Group: `imagebuilder` (RHEL 8, `decommissioning`), the VM `grow-test-rhel2`
(`failed`), and `filer1` (TrueNAS, which hosts the Origin; static `[truenas]` only). labserver3 and labserver4
are **no longer in NetBox at all**. `pinger` is not in NetBox yet and gets `cloud`/`stable` when it is
registered (#27).

Open questions for #30 and #31:

- **Debian 12 and Raspberry Pi OS Bookworm.** The supported clients are Debian 13 and RHEL 10, and #23 does
  not add Debian 12. By NetBox, 18 of the 27 unchecked hosts are Bookworm or Debian 12 (the other 9 are Proxmox), but
  NetBox's platform was wrong for every host that could be checked. A read-only fact gather from the
  controller settles it in one run:
  `~/ansible-venv/bin/ansible all -i nb_inventory.yml --vault-password-file vault/vault_pass.txt -T 10 -m setup -a 'filter=ansible_distribution*,ansible_architecture' -o`,
  run as `ansible` on pi5 from `/etc/ansible-lab-config`. Each Group's Rollout needs its hosts on a
  supported OS first, or an explicit decision. Correcting NetBox's platforms would help too.
- **Saddlehorn's Proxmox version.** The plan's first `proxmox-node` wave is Saddlehorn (labserver5–7)
  "so a cluster-wide effect shows on the older PVE 8 cluster first", but NetBox says PVE 9 for all three.
  If they were upgraded, the first wave loses that reason.
- **The Pis' architecture.** pi5, pi6 and pi7 are aarch64. The others are unchecked (Raspberry Pi OS can be 32-bit).
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
- Confirm before outward-facing actions (issues, PRs, pushes) unless asked. Auto mode also blocks filing an
  issue the user did not ask for.

## Other loose ends

- grmhay/packer-service#111 (needs-triage): raise the Debian 13 and RHEL 10 templates' default root disk to
  100G (amended from 60G on 2026-10-20), so Nix hosts built from them don't fill `/`. Every VM from those
  templates is then at least 100G; vm-service `--disk` only grows.

- pidns1 and pidns2 report different `hayweb.org` SOA serials: seen 2026-10-16, still different on 2026-10-19
  (1771979346 on 192.168.40.17, 1771807930 on 192.168.50.17). Not investigated.
- homelab-opscontrolplane: optional truenas-cert-pusher change to log the "waiting for certificate" state at INFO
  without backoff (offered, not filed).
