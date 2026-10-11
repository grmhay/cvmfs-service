# Runbook: MinIO rename + Let's Encrypt cutover (Phase 0)

**Done 2026-10-11** (homelab-opscontrolplane#126). What is in place is recorded in
`server/minio/RUNBOOK.md` §1. Owners of each piece:

| Step | Where | State |
|---|---|---|
| `minio.hayweb.org` CNAME in internal BIND | dns-service (pidns1, pidns2) | done |
| Caddy DNS-01 name + `truenas-cert-pusher` | `homelab-opscontrolplane`: a sidecar in Caddy's stack, not its own stack (it reads Caddy's certificate volume, and volumes are not shared across stacks) | done |
| TrueNAS: MinIO app uses the pushed cert; S3 API stays on 9000 | the pusher, automatically, on every renewal | done |
| Loki on pi2: endpoint + drop self-signed trust | by hand (Loki is not under Ansible) | done |
| Verify | `nix run .#verify-origin` from a LAN host and from a cloud host | TLS checked from a LAN host; the full run waits for the bucket (§2) and the cloud-host check is still open |

Do all of it in one window. Alloy buffers while Loki restarts.
