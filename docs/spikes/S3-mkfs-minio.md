# S3 — `cvmfs_server mkfs` against MinIO, publish, read back through nginx

On a throwaway Debian 13 VM with the `cvmfs_publisher` role's package set, **a scratch bucket**
(`cvmfs-spike`, same policy) and a scratch key — never the real bucket.

- [x] `s3.conf` as in the role; `cvmfs_server mkfs -s /etc/cvmfs/s3.conf -w http://<vm>/cvmfs/spike.hayweb.org spike.hayweb.org`.
      Known failure: "failed loading reflog (3 - network failure)" → check `CVMFS_S3_DNS_BUCKETS=false`, the API port, TLS trust.
- [x] A transaction that `nix copy`s `nixpkgs#hello` for both systems into `local?root=/cvmfs/spike.hayweb.org` and `file:///cvmfs/spike.hayweb.org/cache?compression=none`, then publishes.
- [x] Objects appear in the bucket; `.cvmfspublished` fetchable anonymously; listing refused.
- [x] nginx (role `cvmfs_nginx_cache`) on the same VM; `curl -I http://<vm>/cvmfs/spike.hayweb.org/.cvmfspublished` → 200, second request `X-Cache-Status: HIT` for a `data/` object, `MISS`/short TTL for the manifest.
- [x] A second VM with `cvmfs_client` probes the repository through nginx; `ls /cvmfs/spike.hayweb.org/nix/store` shows the hello closure.
- [x] `cvmfs_server check` clean. Then `cvmfs_server rmfs` and delete the scratch bucket.

Run with `spikes/s3-scratch-bucket.sh` (by hand: scratch bucket + key, keys straight to the VM),
`spikes/s3-publish.sh mkfs|publish|check|rmfs` (on the VM), `spikes/s3-cache.yml` (nginx role) and
`spikes/s3-client.yml` (client role on the second VM).

## Results (2026-10-19, Debian 13 x86_64 VMs `s3-pub` + `s3-client`, CVMFS 2.14.1, Nix 2.30.0, nginx 1.26.3)

The first attempt (2026-10-12) stopped at publish on grmhay/ansible-lab-config#116 (uploads from
VLAN 20 to filer1 at ~15 KB/s). After that fix, the spike ran again from fresh VMs and an empty
scratch bucket.

| Step | State |
|---|---|
| mkfs against MinIO | **ok**, with `-w` pointing at the bucket (finding 2) |
| Transaction: hello for both systems into the lower store and the binary cache | **ok** |
| Publish | **ok**, 37 s for the hello closures of both systems |
| Objects in the bucket; `.cvmfspublished`, `.cvmfswhitelist` anonymous; listing refused | **ok** (`AccessDenied` on the listing) |
| Nested catalogs from the dirtab | **ok**: one catalog per store path, plus `/cache/*` and `/profiles/canary/spike` |
| nginx role: manifest through the Cache | **ok**: 200, `Cache-Control: max-age=61` |
| nginx role: `data/` object | **ok**: first fetch `MISS`, second `HIT`, `max-age=259200` |
| Client probe through nginx (`s3-client`) | **ok**: `cvmfs_config probe` OK; `/cvmfs/spike.hayweb.org/nix/store` lists the hello closure for both systems |
| `cvmfs_server check`, `rmfs` | **ok** |
| Destroy the VMs | **ok** (vm-service, VMIDs 111 and 112) |
| Delete the scratch bucket and account | **ok**, by hand |

The profile links point at absolute `/nix/store/...` paths, so `hello` runs only where the Union
Store merges the Lower Store into `/nix/store`. That is by design and out of this spike's scope.

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
6. **`apache2` is not needed with an S3 upstream.** mkfs, publish, `check` and the mount all
   worked with it stopped and disabled. Dropped from `cvmfs_publisher`'s package set: it would only
   hold port 80 if the Publisher and the Cache ever share a host.
7. **The publish dirtab works.** `server/cvmfs/cvmfsdirtab` gives one nested catalog per store
   path. `publish/publish.sh` now installs it as `.cvmfsdirtab` in every transaction; the flake app
   wrapper passes its store path as `CVMFS_DIRTAB`.
8. **"Updating global JSON information... fail" is harmless.** mkfs and rmfs print it because
   `cvmfs_server` writes `info/v1/repositories.json` only when a local `/srv/cvmfs/info` exists,
   which an S3 upstream never has. Clients do not read it.

## Open: the resolver refuses the Publisher after a burst of lookups

Not a CVMFS or MinIO problem, and not fixed in this repo. After publish, and again after
`cvmfs_server check`, both resolvers in the VM's `resolv.conf` (192.168.40.17 and 192.168.50.17)
answered `REFUSED` to every query from `s3-pub`, while `s3-client` and the workstation on the same
VLAN got answers. The refusals cleared after a few minutes. That matches a per-client query rate
limit on the resolvers (Pi-hole's default is 1000 queries per 60 s, answered with `REFUSED`). A
publish with 16 parallel S3 connections looks up `minio.hayweb.org` for each request. The spike
finished with `minio.hayweb.org` pinned in `s3-pub`'s `/etc/hosts`.

The long-lived Publisher needs one of: a local caching resolver, an exemption from the rate limit
for the Publisher, or a higher limit. Decide before #5 builds the Publisher.

Result: **done**. Every check passed, findings 1–8 are in the roles and `publish/publish.sh`, and the
scratch bucket and spike VMs are gone. The resolver finding above stays open for #5.
