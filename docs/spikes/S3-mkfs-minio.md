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

Result: _pending_
