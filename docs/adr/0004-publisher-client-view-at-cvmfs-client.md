# The Publisher mounts its client view of the Repository at /cvmfs-client, not /cvmfs

The Publisher is also a union-mode client of its own Repository (plan Phase 1). On a Stratum 0,
`cvmfs_server mkfs` owns `/cvmfs/nix.hayweb.org`: it writes two `/etc/fstab` lines, a read-only
`cvmfs2` instance on `/var/spool/cvmfs/nix.hayweb.org/rdonly` and an overlay on
`/cvmfs/nix.hayweb.org`, and opens and closes transactions on that overlay. `cvmfs_client` then added
its own `cvmfs` fstab entry on the same path (#15). That entry either replaces or shadows the server's
mount, and a Union Store on top of it ties the build host's `/nix/store` to the transaction's scratch
area.

On the Publisher only, `publisher.yml` sets `cvmfs_client_mountpoint: /cvmfs-client/<repo>`. Every
other host keeps the default, `/cvmfs/<repo>`. `cvmfs_client` mounts there, and `nix_union_store`
takes the Lower Store, the check path, the Group Profile on PATH and its systemd ordering
(`RequiresMountsFor`) from the same variable. The server's `/cvmfs/<repo>` stays as `cvmfs_server`
left it, and `publish.sh` and `promote.sh` still write there. The client view reads through the Cache,
like every other host, so the Publisher sees what clients see. This is a playbook property, not a
host fact, so it does not come from NetBox.

Why the two instances do not collide (CVMFS 2.14.1 source and docs):

- `mount.cvmfs` takes any mountpoint. The docs' fstab sample mounts `atlas.cern.ch` on `/mnt/test`
  (client docs, "Mounting"). It reads `/etc/cvmfs/default.local` and `config.d/`, so the client
  instance uses `cvmfs_cache_base` (`/var/lib/cvmfs`), its socket under that directory and the
  Cache URL.
- The server's rdonly instance is mounted with `config=/etc/cvmfs/repositories.d/<repo>/client.conf:…`.
  With `config=`, cvmfs2 parses only those files and never reads `default.local` or `config.d/`
  (`loader.cc`). That `client.conf` gives it its own `CVMFS_CACHE_BASE` and `CVMFS_RELOAD_SOCKETS`
  (`/var/spool/cvmfs/<repo>/cache`), its own `CVMFS_TALK_SOCKET`, and the Origin as its server. So no
  setting in `cvmfs_client`'s files reaches it.
- The rdonly mount's fsname is the repository name, not `cvmfs2`, so `cvmfs_config`'s mount list
  (`reload`, `umount`, `status`) leaves it out.

## Considered Options

- **Skip the client mount on the Publisher; the Lower Store is the server's `/cvmfs/<repo>`.**
  Rejected: during a transaction that mount is writable and shows unpublished paths, so the
  Publisher's `/nix/store` would read the scratch area, not what clients get.
- **`CVMFS_MOUNT_DIR=/cvmfs-client` in `default.local`.** It would let `cvmfs_config probe` find the
  mount. Rejected: the client parameters appendix says the default `/cvmfs` "cannot be overwritten",
  and mount.cvmfs does not use it to choose the mountpoint anyway.
- **Drop the Publisher-as-client check and verify Phase 1 from a Canary host only.** Rejected for
  now: a Union Store on the build host is how Phase 1 is checked before any other host mounts.

## Consequences

- `cvmfs_config probe` looks only at `$CVMFS_MOUNT_DIR/<repo>`. On the Publisher that is the server's
  overlay, so the probe would fail there by design. `cvmfs_client` runs it only on the default
  mountpoint. Every host also probes with `cvmfs_talk -i <repo>`, which finds the client instance
  through its config: the instance must be mounted on `cvmfs_client_mountpoint`, and its active host
  must be one of `cvmfs_server_urls` (the Cache).
- If `/etc/fstab` has a client `cvmfs` line on `/cvmfs/<repo>` on a host whose client view is
  elsewhere, `cvmfs_client` fails before mounting and says which line to remove.
- After a publish, the Publisher's Union Store sees new paths only after the Cache and the repository
  TTL let them through, which is the same delay every client has (ADR 0003). Builds land in the RW
  Branch in the meantime.
- Docs that write `/cvmfs/nix.hayweb.org` for the Lower Store mean the client view. On the Publisher,
  that is `/cvmfs-client/nix.hayweb.org`.
- References: [client docs, Mounting](https://cvmfs.readthedocs.io/en/stable/cpt-configure/#mounting),
  [CVMFS_MOUNT_DIR](https://cvmfs.readthedocs.io/en/stable/apx-parameters/#cvmfs_mount_dir),
  [Stratum 0 mount layout](https://cvmfs.readthedocs.io/en/stable/apx-serverinfra/),
  `cvmfs/loader.cc`, `mount/mount.cvmfs.cc`, `cvmfs/cvmfs_config` and
  `cvmfs/server/cvmfs_server_common.sh` at tag `cvmfs-2.14.1`.
