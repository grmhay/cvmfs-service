# cvmfs-service

Fleet software distribution: Nix-built Profiles published once to a CernVM-FS repository and seen
on demand by every host under `/nix/store`, with CVMFS managing a quota-bounded local cache.

## Language

**Repository**:
The single CernVM-FS repository `nix.hayweb.org`. Holds the Lower Store, the Binary Cache and the
Profiles for both architectures; store-path hashes keep x86_64 and aarch64 closures apart.
_Avoid_: repo (ambiguous with git), stratum, share

**Publisher**:
The Stratum 0 host (Debian 13 x86_64 VM). Owns the Repository's signing key, builds Profiles (aarch64
via the Builders), and publishes transactions. The only writer.
_Avoid_: stratum 0 (the role, not the host), build server, master

**Origin**:
MinIO at `minio.hayweb.org` (TrueNAS app on filer1) — the Repository's S3 upstream storage. Written
by the Publisher, read only through the Cache.
_Avoid_: bucket (the object inside it), S3, storage

**Cache**:
`cache1.hayweb.org`, an nginx reverse cache in front of the Origin. Clients' `CVMFS_SERVER_URL`.
Not a Squid forward proxy and not a Stratum 1.
_Avoid_: proxy, stratum 1, mirror

**Lower Store**:
`/cvmfs/nix.hayweb.org/nix` — a complete read-only Nix store (`store/` + `var/nix/db`) inside the
Repository. The RO branch of every host's Union Store.
_Avoid_: remote store, shared store, the CVMFS store

**Union Store**:
A host's `/nix/store`: mergerfs of the host's RW Branch over the Lower Store, with the Nix daemon
running a `local-overlay-store` on top. Zero-copy — nothing published is ever duplicated locally.
_Avoid_: overlay (that is the Nix store type, not the filesystem), merged store

**RW Branch**:
`/nix/.rw-store/store`, the host-local writable branch of the Union Store. Holds only what the host
built or copied itself. The only thing local GC touches.
_Avoid_: upper layer (overlayfs vocabulary), local store

**Binary Cache**:
`/cvmfs/nix.hayweb.org/cache` — the same closures as the Lower Store in narinfo/nar form
(uncompressed). The fallback for hosts in cache Mode; never the primary path.
_Avoid_: substituter (the nix.conf setting), nar cache

**Mode**:
How a host assembles `/nix/store`: `union` (default), `cache` (plain local `/nix` fed from the Binary
Cache), `thin` (read-only bind of the Lower Store, no daemon). An Ansible/NetBox variable.
_Avoid_: tier, class, flavour

**Group**:
A host class with one composite Profile: `base`, `docker-host`, `proxmox-node`, `cloud`, `builder`.
Every Group's Profile includes `base`. Recorded in NetBox (`nix_group`).
_Avoid_: role (Ansible word), host type

**Profile**:
A `buildEnv` for one Group and one system, e.g. `profile-base` for `aarch64-linux`. Hosts put its
`bin/` on PATH. File collisions fail the build, never PATH order.
_Avoid_: environment, package set, bundle

**Channel**:
`canary` or `stable`. `/cvmfs/nix.hayweb.org/profiles/<channel>/<group>/<system>` is a symlink to a
Profile store path. A host follows exactly one Channel (NetBox `nix_channel`).
_Avoid_: branch, stage, ring

**Publish**:
One CVMFS transaction: copy new Profile closures into the Lower Store and the Binary Cache, flip the
`canary` symlinks, sign. Triggered by the Publisher's reconciler from `master`.
_Avoid_: deploy, release, push

**Promote**:
Re-point `stable` symlinks at what `canary` points to, for one Group or all. No rebuild. Committed to
`profiles/pointers.json` as the audit trail.
_Avoid_: release, graduate, ship

**Builder**:
`pi5` and `pi6`: aarch64 hosts the Publisher sends remote builds to (NetBox tag `nix-builder`).
_Avoid_: build node, worker, agent

**Canary host**:
A host on the `canary` Channel: `pi7`, `nixcanary-deb1`, `nixcanary-rhel1` (NetBox tag `nix-canary`).
_Avoid_: test host, staging host

## Relationships

- The **Publisher** builds a **Profile** per **Group** and system, using the **Builders** for aarch64
- A **Publish** writes to the **Repository** via the **Origin**; clients read it via the **Cache**
- Every host mounts the **Repository**; in union **Mode** its **Union Store** = **RW Branch** ∪ **Lower Store**
- A host's PATH follows one **Channel** and one **Group**; **Promote** moves `stable` to `canary`'s Profiles
- The **Binary Cache** mirrors the **Lower Store** for hosts in cache **Mode**
