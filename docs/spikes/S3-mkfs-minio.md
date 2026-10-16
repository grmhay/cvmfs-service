# S3 — `cvmfs_server mkfs` against MinIO, publish, read back through nginx

On a throwaway Debian 13 VM with the `cvmfs_publisher` role's package set, **a scratch bucket**
(`cvmfs-spike`, same policy) and a scratch key — never the real bucket.

- [ ] `s3.conf` as in the role; `cvmfs_server mkfs -s /etc/cvmfs/s3.conf -w http://<vm>/cvmfs/spike.hayweb.org spike.hayweb.org`.
      Known failure: "failed loading reflog (3 - network failure)" → check `CVMFS_S3_DNS_BUCKETS=false`, the API port, TLS trust.
- [ ] A transaction that `nix copy`s `nixpkgs#hello` for both systems into `local?root=/cvmfs/spike.hayweb.org` and `file:///cvmfs/spike.hayweb.org/cache?compression=none`, then publishes.
- [ ] Objects appear in the bucket; `.cvmfspublished` fetchable anonymously; listing refused.
- [ ] nginx (role `cvmfs_nginx_cache`) on the same VM; `curl -I http://<vm>/cvmfs/spike.hayweb.org/.cvmfspublished` → 200, second request `X-Cache-Status: HIT` for a `data/` object, `MISS`/short TTL for the manifest.
- [ ] A second VM with `cvmfs_client` probes the repository through nginx; `ls /cvmfs/spike.hayweb.org/nix/store` shows the hello closure.
- [ ] `cvmfs_server check` clean. Then `cvmfs_server rmfs` and delete the scratch bucket.

Run with `spikes/s3-scratch-bucket.sh` (by hand: scratch bucket + key, keys straight to the VM),
`spikes/s3-publish.sh mkfs|publish|check|rmfs` (on the VM) and `spikes/s3-cache.yml` (nginx role).

## Results so far (2026-10-12, Debian 13 x86_64 VM `s3-pub`, CVMFS 2.14.1, Nix 2.30.0)

| Step | State |
|---|---|
| mkfs against MinIO | **ok**, once `-w` points at the bucket (finding 2) |
| Transaction: hello for both systems into the lower store and the binary cache | **ok** up to the upload |
| Publish | **blocked**: uploads from VLAN 20 to filer1 crawl at ~15 KB/s (`503 RequestTimeout`, curl error 65); grmhay/ansible-lab-config#116. Not CVMFS or MinIO: pi7 on VLAN 40 uploads at 23 MB/s |
| nginx role, manifests through the Cache | **ok** (`.cvmfsreflog`, `.cvmfswhitelist` → 200) after finding 3; `X-Cache-Status: HIT` on `data/` not yet shown |
| Client probe through nginx | pending (publish) |
| `cvmfs_server check`, `rmfs`, delete scratch bucket | pending |

## Findings folded into the roles

1. **There is no `cvmfs-config-none`** for Debian 13 or EL10 in the cernvm repositories (only
   `cvmfs-config-default`, which `cvmfs` depends on). Dropped from `cvmfs_publisher` and
   `cvmfs_client`; `default.local` already limits the mounts to our repository.
2. **`mkfs -w` is the bucket, not the Cache.** `cvmfs_server` appends `/<repo>` to it
   (`CVMFS_STRATUM0`), so the role's old value doubled the repository name. And the Publisher reads
   `.cvmfsreflog` and `.cvmfspublished` back right after writing them: through nginx (30 s manifest
   TTL) it got the previous copies and the initial commit failed with "data corruption in
   .cvmfsreflog", even on an empty bucket and empty cache. With `-w https://minio.hayweb.org:9000/<bucket>`
   mkfs succeeds, and the Publisher no longer needs cache1 to be up. `cvmfs_stratum0_url` changed.
3. **nginx role, two bugs.** The manifest location proxied to `<bucket>/cvmfs/<repo>/…` (the `/cvmfs`
   prefix leaked into the bucket key); it now captures `<repo>/.cvmfs…`. And
   `proxy_ssl_verify_depth` defaulted to 1, which rejects the Let's Encrypt chain ("unable to get
   local issuer certificate"); set to 3.
4. **The publisher policy is enough.** Uploads with CVMFS's `x-amz-acl: public-read` header succeed;
   `s3:PutObjectAcl` is not needed.
5. **mkfs needs an empty bucket.** After `rmfs` the objects stay, mkfs refuses without `-I`, and a
   re-created repository collides with copies still in the Cache. Recorded in the MinIO runbook.
6. `apache2` (in the role's package set) is not needed with an S3 upstream: mkfs and the mount work
   with it stopped. Left in the role until a publish proves the same; it only matters if the
   Publisher and the Cache ever share a host (both want port 80).

Not yet folded: `publish/publish.sh` does not install `server/cvmfs/cvmfsdirtab`. The spike installs
it in the transaction; fold it in once a publish shows the nested catalogs.

Result: _blocked on grmhay/ansible-lab-config#116_
