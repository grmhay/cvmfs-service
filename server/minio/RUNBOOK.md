# Runbook: MinIO as the CVMFS Origin

MinIO is the TrueNAS app on `filer1`, built by hand. This runbook is the only place the bucket,
policy and credentials are created — the Ansible roles **verify**, they never create (decision Q4c).

## 1. Rename and certificate (prerequisite, shared with Loki)

Done once, in one change window, because Loki on pi2 stores to the same MinIO.

1. Internal BIND: `minio.hayweb.org` → filer1 (CNAME). Confirm `dig minio.hayweb.org` from a LAN host
   and from a cloud host over OpenVPN (internal DNS is pushed over the tunnel).
2. `homelab-opscontrolplane`: add `minio.hayweb.org` to Caddy's DNS-01 names; deploy the
   `truenas-cert-pusher` stack (watches the cert, pushes to the TrueNAS API; API key in SOPS).
3. TrueNAS: point the MinIO app at the pushed certificate; restart the app.
4. The S3 **API** port is `9000` (the console is `:9002`). Confirmed in spike S1: `/minio/health/live`
   answers 200 there with `Server: MinIO`. Keep it when the app gets the new cert.
5. pi2 Loki (hand-managed): change the S3 endpoint to `https://minio.hayweb.org:9000`, remove any
   `insecure_skip_verify`/self-signed CA, restart Loki, watch ingestion resume (alloy buffers).

## 2. Bucket, policy, service account

From a `nix develop` shell (`mc` is in it):

```sh
mc alias set filer1 https://minio.hayweb.org:9000 <root-user> <root-password>
mc mb filer1/cvmfs
mc anonymous set-json server/minio/bucket-policy.json filer1/cvmfs   # GetObject only; no listing
mc admin user svcacct add filer1 <root-user> --name cvmfs-publisher \
   --policy <(cat <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:*"],"Resource":["arn:aws:s3:::cvmfs","arn:aws:s3:::cvmfs/*"]}]}
EOF
)
```

Put the service-account key pair into `secrets/publisher.enc.yaml` (`minio_access_key`,
`minio_secret_key`) with `sops --encrypt --in-place`.

## 3. Verify

```sh
CVMFS_REPOSITORY=nix.hayweb.org MINIO_URL=https://minio.hayweb.org:9000 \
  CACHE_URL=http://cache1.hayweb.org nix run .#verify-origin
```

Before the Repository exists the two manifest checks fail; the TLS and policy checks must pass.

## Known pitfalls (CVMFS on S3)

- `cvmfs_server mkfs` against an existing bucket **re-initialises** the repository. Never re-run it
  on a populated bucket; import with `cvmfs_server import` instead.
- A lost `.cvmfsreflog`: `cvmfs_server check -r`. A lost `.cvmfspublished`: re-upload from the
  publisher's `/srv/cvmfs/<repo>` copy, then `cvmfs_server resign -p`.
- Clients must be able to fetch `.cvmfspublished` over plain HTTP at the `-w` URL given to `mkfs`
  (that is the Cache's URL, not the bucket's).
