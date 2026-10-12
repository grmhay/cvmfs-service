# Runbook: MinIO as the CVMFS Origin

MinIO is the TrueNAS app on `filer1`, built by hand. This runbook is the only place the bucket,
policy and credentials are created — the Ansible roles **verify**, they never create (decision Q4c).

## 1. Rename and certificate (prerequisite, shared with Loki)

**Done 2026-10-11** (homelab-opscontrolplane#126, PR #140). Kept as the record of what is in place and
how it renews.

Done once, in one change window, because Loki on pi2 stores to the same MinIO.

- [x] Internal BIND: `minio.hayweb.org` CNAME → `filer1.hayweb.org` (dns-service, pidns1 and pidns2).
      Confirmed from a LAN host. Not yet checked from a cloud host over OpenVPN.
- [x] skyline's Caddy issues `minio.hayweb.org` by name.com DNS-01. The site only holds the
      certificate (it answers 404); MinIO is served by filer1.
- [x] The `truenas-cert-pusher` sidecar in Caddy's stack (repo `grmhay/truenas-cert-pusher`) imports
      the certificate into TrueNAS and points the `minio` app at it (`network.certificate_id`), which
      redeploys the app. Renewals follow the same path with no manual step. Its TrueNAS API key is
      `TRUENAS_API_KEY` in the ops repo's `secrets/prod/caddy.enc.yaml`; rotation is in that repo's
      `docs/recovery.md`.
- [x] The S3 **API** port is `9000` (the console is `:9002`). Confirmed in spike S1:
      `/minio/health/live` answers 200 there with `Server: MinIO`; after the switch it does so with a
      verified Let's Encrypt chain.
- [x] pi2 Loki (hand-managed): S3 endpoint `https://minio.hayweb.org:9000`, no
      `insecure_skip_verify` or self-signed CA.

Check at any time:

```sh
openssl s_client -connect minio.hayweb.org:9000 -servername minio.hayweb.org </dev/null 2>/dev/null \
  | openssl x509 -noout -issuer -subject -enddate      # Let's Encrypt, CN=minio.hayweb.org
```

filer1's own API and UI (port 443) keep TrueNAS's self-signed certificate; only MinIO moved.

## 2. Bucket, policy, service account

From the repo root in a `nix develop` shell (`mc`, `sops` and `jq` are in it), in your own terminal:

```sh
mc alias set filer1 https://minio.hayweb.org:9000      # prompts for the root user and password
mc mb filer1/cvmfs
mc anonymous set-json server/minio/bucket-policy.json filer1/cvmfs   # GetObject only; no listing
server/minio/create-publisher-key.sh filer1 <root user>
mc alias remove filer1                                 # mc keeps the root password in ~/.mc in plain text
```

`create-publisher-key.sh` creates the `cvmfs-publisher` service account with
`publisher-policy.json` and writes its keys to `secrets/publisher.enc.yaml`
(`minio_access_key`, `minio_secret_key`), encrypted for the ops age recipient. The secret
key is never shown or written in plain text, and only the public recipient is needed, so any
workstation can run it. Later keys (`nixbuild_private_key`, `deploy_key_private`) are added
with `sops --set` on a host with the age key.

The publisher's policy covers objects in `cvmfs` plus listing it. It deliberately leaves out
bucket administration, so a leaked publisher key cannot change the anonymous policy or delete
the bucket. If `cvmfs_server` hits `AccessDenied` on an operation the policy lacks, add that
action to `publisher-policy.json` and update the account with
`mc admin user svcacct edit filer1 <access key> --policy server/minio/publisher-policy.json`.
Untested until the first `cvmfs_server mkfs` (#3): CVMFS sends an `x-amz-acl` header on uploads
(`CVMFS_S3_X_AMZ_ACL`, default `public-read`); if PUTs are refused, `s3:PutObjectAcl` is the
first candidate.

## 3. Verify

```sh
CVMFS_REPOSITORY=nix.hayweb.org MINIO_URL=https://minio.hayweb.org:9000 \
  CACHE_URL=http://cache1.hayweb.org nix run .#verify-origin
```

Before the Repository exists the three Repository checks fail (`.cvmfspublished` from the bucket
and both cache checks). The TLS check and the two policy checks must pass: an anonymous GET of a
missing object returns `NoSuchKey` (the bucket exists and the policy allows reads) and an
anonymous LIST returns `AccessDenied`.

## Known pitfalls (CVMFS on S3)

- `cvmfs_server mkfs` against an existing bucket **re-initialises** the repository. Never re-run it
  on a populated bucket; import with `cvmfs_server import` instead.
- A lost `.cvmfsreflog`: `cvmfs_server check -r`. A lost `.cvmfspublished`: re-upload from the
  publisher's `/srv/cvmfs/<repo>` copy, then `cvmfs_server resign -p`.
- Clients must be able to fetch `.cvmfspublished` over plain HTTP at the `-w` URL given to `mkfs`
  (that is the Cache's URL, not the bucket's).
