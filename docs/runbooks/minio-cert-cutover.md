# Runbook: MinIO rename + Let's Encrypt cutover (Phase 0)

See `server/minio/RUNBOOK.md` §1 for the steps. Owners of each piece:

| Step | Where |
|---|---|
| `minio.hayweb.org` CNAME in internal BIND | dns-service / BIND config |
| Caddy DNS-01 name + `truenas-cert-pusher` stack | `homelab-opscontrolplane` (issue there) |
| TrueNAS: MinIO app uses the pushed cert; confirm the S3 API port | by hand on filer1 |
| Loki on pi2: endpoint + drop self-signed trust | by hand (Loki is not under Ansible) |
| Verify | `nix run .#verify-origin` from a LAN host and from a cloud host |

Do all of it in one window. Alloy buffers while Loki restarts.
