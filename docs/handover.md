# Handover

State of the work as of **2026-10-16**. On hold until the network fix below lands. Design: `plans/0001-nix-over-cvmfs.md`; vocabulary: `CONTEXT.md`.

## Where things stand

Phase 0 (prerequisites and spikes) is nearly done:

| Item | State |
|---|---|
| S1 packages (#1) | done: `docs/spikes/S1-packages.md` |
| S2 union store (#2), sandbox groundwork (#6: #7, #8, #10–#12) | done: `docs/spikes/S2-union-store.md`, ADR 0002 |
| MinIO rename + Let's Encrypt cert (homelab-opscontrolplane#126) | done 2026-10-11; the `truenas-cert-pusher` sidecar in Caddy's stack on skyline renews it |
| Bucket `cvmfs`, anonymous GetObject policy, `cvmfs-publisher` account (#4) | done; keys in `secrets/publisher.enc.yaml`. **Open:** the `verify-origin` run from a cloud host over OpenVPN (deferred) |
| S3 mkfs/publish against MinIO (#3) | **blocked** on grmhay/ansible-lab-config#116 |
| Long-lived VMs: publisher, cache1, canaries (#5) | not started (wait for #116: the Publisher sits on VLAN 20) |
| Nix sandbox on the union (#13) | waits for an upstream Nix release with the fix (#9, by hand) |

## The blocker: ansible-lab-config#116

Uploads from VLAN 20 (every vm-service VM, and this workstation) into filer1 (192.168.10.91) crawl at about 15 KB/s with heavy packet loss. `cvmfs_server publish` times out (`503 RequestTimeout`, curl error 65). The same upload from pi7 on VLAN 40 runs at 23 MB/s, and uploads from VLAN 20 to the internet are fast. Measurements, ruled-out causes and a reproduction command are in the issue. The fix is in the network (inter-VLAN routing, or filer1's NIC/switch port), not in this repo.

Check it is fixed (from a VLAN 20 host; healthy is well under a second):

```sh
head -c 3000000 /dev/urandom >/tmp/q3
curl -s -o /dev/null -H 'Expect:' --max-time 40 --data-binary @/tmp/q3 \
  -w '%{http_code} %{time_total}s\n' https://minio.hayweb.org:9000/cvmfs/x
```

## Resuming spike S3 (#3)

The spike VMs were destroyed on 2026-10-16. Progress, findings and what is still open are in `docs/spikes/S3-mkfs-minio.md`; the role fixes are already on master (644c0d8).

1. If they still exist, delete the old scratch bucket and its orphaned account by hand: `spikes/s3-scratch-bucket.sh delete filer1 admin`. Its keys were only on the destroyed VM.
2. Create two Debian 13 VMs with vm-service, one at a time, using `--no-backup --ssh-keys "$(cat ~/.ssh/id_ed25519.pub)"` (log in as `ansible@`).
3. By hand: `spikes/s3-scratch-bucket.sh create filer1 admin ansible@<publisher vm>`. Set the `mc alias` in the same shell first.
4. Copy the repo to the VM (no rsync on the template; use `tar | ssh`), then:
   - `sudo spikes/s3-publish.sh mkfs`
   - nginx: from `ansible/`, `ansible-playbook -i <vm>, -u ansible ../spikes/s3-cache.yml`. Disable `apache2` first: it holds port 80 on a shared host.
   - `sudo spikes/s3-publish.sh publish`, then `check`
   - a second VM with `cvmfs_client` pointed at the first VM's nginx
   - `rmfs`, then delete the scratch bucket.
5. Fold in what is still open: install `server/cvmfs/cvmfsdirtab` in `publish/publish.sh` once nested catalogs are shown, and decide whether `apache2` stays in `cvmfs_publisher`.

Lessons from the first attempt:
- mkfs needs an **empty** bucket, and the Cache must not hold copies from an earlier attempt. To start over, empty the bucket (the scratch key may list and delete) and the nginx cache dir.
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
