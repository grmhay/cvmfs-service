# Handover

State of the work as of **2026-10-20**. Design: `plans/0001-nix-over-cvmfs.md`; vocabulary: `CONTEXT.md`.

Phase 0 (prerequisites and spikes) is done apart from one deferred check. All four long-lived VMs
exist and #5 is closed. **Phase 1 (the Origin) is ready to run**: NetBox is the inventory source
(grmhay/ansible-lab-config#113, closed 2026-10-20), and the Publisher's first-run problems found on
2026-10-19 (#15, #16, the master key, nix.conf) are fixed in collection `v0.4.0`, but none of it has
run on a real host. ansible-lab-config still pins the collection at `v0.1.0`. #14, the chroot-fix Nix fork on the canaries, is
done: all three canaries run the fork in union Mode with the sandbox on.

## Where things stand

| Item | State |
|---|---|
| S1 packages (#1) | done: `docs/spikes/S1-packages.md` |
| S2 union store (#2), sandbox groundwork (#6: #7, #8, #10–#12) | done: `docs/spikes/S2-union-store.md`, ADR 0002 |
| S3 mkfs/publish against MinIO (#3) | done and closed 2026-10-19: `docs/spikes/S3-mkfs-minio.md` |
| MinIO rename + Let's Encrypt cert (homelab-opscontrolplane#126) | done 2026-10-11; the `truenas-cert-pusher` sidecar in Caddy's stack on skyline renews it |
| Bucket `cvmfs`, policy, `cvmfs-publisher` account (#4) | done; keys in `secrets/publisher.enc.yaml`. **Open by choice:** the `verify-origin` run from a cloud host over OpenVPN |
| Long-lived VMs (#5) | done and closed 2026-10-20: canaries `nixcanary-deb1` (103), `nixcanary-rhel1` (109); `publisher` (111, 192.168.20.118, 100 GB) and `cache1` (112, 192.168.20.119, 120 GB). NetBox roles, tags and custom fields set (ansible-lab-config#113) |
| Publisher first run (#15, #16) | fixed on master, not yet run: see "Next: Phase 1" |
| Upstream chroot-parent fix (#9) | the user's, by hand. Nothing is filed on NixOS/nix by an agent |
| Nix sandbox on the union (#6 parent, #13) | fleet-wide: waits for a Nix release with the #9 fix, then a Determinate installer that ships it |
| Chroot-fix fork on the canaries (#14) | done 2026-10-19: `docs/canary-nix-fork.md`. `pi7`, `nixcanary-deb1` and `nixcanary-rhel1` run `2.30.0+chrootfix` in union Mode over the stand-in Lower Store `/srv/lower`, sandbox on. Their `nix_union_sandbox`/`nix_sandbox_fork` settings are not yet in NetBox or the inventory |

## Next: Phase 1, the Origin (`publisher.yml` on VMID 111)

Runs from ansible-lab-config's Semaphore templates (`cvmfs: publisher` / `cache` / `builders` /
`clients (canaries)`), with NetBox as the inventory (#113 done: `nix_publisher` = publisher,
`nix_cache` = cache1, `tag_nix_builder` = pi5, pi6, `tag_nix_canary` = the three canaries). Do not run it
with a hand-made inventory.

**Collection tag:** `v0.4.0` (2026-10-20) is the latest and includes everything below plus #14's
`nix_sandbox_fork`. ansible-lab-config still pins this repo at `v0.1.0`; move that pin to `v0.4.0`
before the first `cvmfs: publisher` run (asked for in the closing comment on #5; no `v0.1.1` is needed).

Fixed on master on 2026-10-19, none of it run on a real host yet:

- **Resolver rate limit** (1fadef6): `cvmfs_publisher` installs a local caching systemd-resolved stub
  forwarding to `publisher_dns_upstreams`, no public fallback, with a dig check through the stub. On the
  first publish and `cvmfs_server check`, confirm no `REFUSED` (S3 doc, "Resolver rate limit").
- **Order + master key** (d03e127): the repository part (mkfs, public key) runs before `cvmfs_client`
  and `nix_union_store`; the publishing part comes last. A guard fails the play if
  `/etc/cvmfs/keys/<repo>.masterkey` is still on the Publisher (except on the mkfs run, or with
  `publisher_allow_masterkey: true` during `resign`). `nix run .#masterkey-escrow` streams it into
  `secrets/masterkey.enc.yaml` and shreds it after a hash match.
- **Mount clash** (#15, ADR 0004): the Publisher's client view is at `/cvmfs-client/nix.hayweb.org`
  (`cvmfs_client_mountpoint`), reading through the Cache; `cvmfs_server` keeps `/cvmfs/nix.hayweb.org`.
- **nix.conf** (dca29c2): `nix_union_store` owns `nix.conf`; the Publisher and builders write
  `/etc/nix/nix.conf.d/*.conf` drop-ins with `extra-trusted-users`. Expect one nix-daemon restart per
  host on the first run after this lands.
- **Empty repository** (#16): `publisher.yml` sets `nix_union_defer_until_published`, so the first runs
  leave `/nix/store` plain until a publish creates the Lower Store. Everywhere else an empty repository fails.
- **Public key home** (#17): the run no longer fetches `.pub` into the play's checkout (lost under
  Semaphore). The Publisher prints it with its sha256 after mkfs and verifies its own copy
  (`cvmfs_public_key_from_host`); the operator commits it at `ansible/roles/cvmfs_client/files/` and
  tags a release, and every other client fails early without it.

The sequence is `docs/runbooks/publisher-bootstrap.md`: playbook → `masterkey-escrow` + commit the
secret and the printed `.pub` → tag + re-vendor → re-run → first publish by hand (`sudo systemctl start cvmfs-publish.service`) →
wait out the TTL → re-run to assemble the union. Watch on that run: the two mounts across a reboot,
`cvmfs_server transaction`/`publish` with the second client instance up, the `findmnt`/`cvmfs_talk`
probe output, and the store migration into the RW Branch.

## The canaries after #14

`pi7`, `nixcanary-deb1` and `nixcanary-rhel1` now run a Union Store over the stand-in Lower Store at
`/srv/lower`, because no Repository existed yet. When the Repository is published, their
`nix_lower_store` moves to the role default (the Repository's `/nix`). The settings for this were passed
with `-e`. Until NetBox or the inventory's group vars set `nix_union_sandbox: "true"` and
`nix_sandbox_fork: true` for the `nix-canary` tag, a `clients (canaries)` run turns their sandbox back off.
#113's custom fields do not include them. The fork stays
until a pin bump. `nix_sandbox_fork` ships in collection `v0.4.0`; earlier tags lack it.

`nixcanary-rhel1` needs root over SSH: a later `wheel` sudo rule asks the `ansible` user for a password.

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
