# Handover

State of the work as of **2026-10-19**. The network blocker (grmhay/ansible-lab-config#116) is fixed and spike S3 has passed. Design: `plans/0001-nix-over-cvmfs.md`; vocabulary: `CONTEXT.md`.

## Where things stand

Phase 0 (prerequisites and spikes) is nearly done:

| Item | State |
|---|---|
| S1 packages (#1) | done: `docs/spikes/S1-packages.md` |
| S2 union store (#2), sandbox groundwork (#6: #7, #8, #10–#12) | done: `docs/spikes/S2-union-store.md`, ADR 0002 |
| MinIO rename + Let's Encrypt cert (homelab-opscontrolplane#126) | done 2026-10-11; the `truenas-cert-pusher` sidecar in Caddy's stack on skyline renews it |
| Bucket `cvmfs`, anonymous GetObject policy, `cvmfs-publisher` account (#4) | done; keys in `secrets/publisher.enc.yaml`. **Open:** the `verify-origin` run from a cloud host over OpenVPN (deferred) |
| S3 mkfs/publish against MinIO (#3) | done 2026-10-19: `docs/spikes/S3-mkfs-minio.md` |
| Long-lived VMs: publisher, cache1, canaries (#5) | canaries done; publisher and cache1 wait on ansible-lab-config#113. Decide the resolver rate-limit fix (S3 doc, "Open") before the Publisher |
| Nix sandbox on the union (#13) | waits for an upstream Nix release with the fix (#9, by hand) |

## Spike S3 (#3)

Done on 2026-10-19 with fresh VMs `s3-pub` (111) and `s3-client` (112) and a fresh scratch bucket.
Results and findings are in `docs/spikes/S3-mkfs-minio.md`. The dirtab is now installed by
`publish/publish.sh`, and `apache2` is gone from `cvmfs_publisher`.

The scratch bucket and both VMs are gone.

One open finding: the resolvers refuse the Publisher after a burst of lookups, which looks like a
rate limit. Pick a fix before #5 builds the Publisher.

Lessons for the next spike on a fresh vm-service VM:
- vm-service's first-boot Ansible run keeps going after `create-vm` returns. Wait for it before using apt.
- A re-created VM keeps its old name, so remove the stale `known_hosts` entry.
- mkfs needs an **empty** bucket, and the Cache must not hold copies from an earlier attempt.
- `-w` is the bucket, never the Cache.

## Standing rules

- VMs come from vm-service, created by the agent, and throwaway ones are destroyed afterwards.
- MinIO buckets, policies and keys are made **by hand** by the user; scripts only prepare the commands.
- Only `*.enc.yaml` is committed (age recipient shared with homelab-opscontrolplane). Never print secret values.
- Nothing is filed on NixOS/nix by an agent; #9 is the user's.
- Confirm before outward-facing actions (issues, PRs, pushes) unless asked.

## Other loose ends

- homelab-opscontrolplane: optional truenas-cert-pusher change to log the "waiting for certificate" state at INFO without backoff (offered, not filed).
- pidns1 and pidns2 report different `hayweb.org` SOA serials (seen 2026-10-16); not investigated.
