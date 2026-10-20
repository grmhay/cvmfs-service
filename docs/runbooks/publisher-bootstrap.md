# Runbook: first run on a fresh Publisher

`cvmfs_server mkfs` creates two keys on the Publisher. The **public key** goes to every host. The
**master key** must not stay on the Publisher: it lives in SOPS and comes back only for a resign
(CLAUDE.md, docs/runbooks/resign.md). This is the one-off sequence that gets both keys where they
belong. Before you start, the Origin bucket must be verified (server/minio/RUNBOOK.md) and
`secrets/publisher.enc.yaml` must hold the MinIO keys, the builder key and the deploy key
(secrets/README.md).

All commands run from the checkout root inside a `nix develop` shell on the workstation.

## 1. Playbook (creates the repository)

```sh
(cd ansible && ansible-playbook playbooks/publisher.yml)
```

`publisher.yml` runs in this order:

1. `cvmfs_publisher` (tasks `repository`): runs mkfs once and fetches the new public key to
   `ansible/roles/cvmfs_client/files/nix.hayweb.org.pub`.
2. `cvmfs_client` and `nix_union_store`: ship that key and mount the client view of the repository
   at `/cvmfs-client/nix.hayweb.org` (through the Cache). mkfs owns `/cvmfs/nix.hayweb.org` here,
   and the client mount leaves it alone (ADR 0004). The repository is still empty: it has no Lower
   Store until the first publish (step 4). So the union store is not assembled yet, and the run
   prints "Union deferred until the first publish". `/nix/store` stays the installer's plain local
   store, which is all the first publish needs (#16).
3. `cvmfs_publisher` (tasks `publishing`): sets up the builders and the clone, then installs the
   resign and publish timers. The publish timer stays off (`publisher_timer_enabled: false`).

On this run the master key is still on the Publisher. The guard ("Master key is not on the
Publisher") lets the run that created the repository finish, and the last task prints a reminder.

Only `publisher.yml` defers the union, through the play variable `nix_union_defer_until_published`.
On any other host an empty repository fails the run at "The Lower Store is there", and so does the
Publisher once its union has been assembled.

## 2. Escrow the master key

```sh
nix run .#masterkey-escrow            # PUBLISHER_HOST=<ssh name> if it is not "publisher"
```

`publish/masterkey-escrow.sh` streams `/etc/cvmfs/keys/nix.hayweb.org.masterkey` over ssh straight
into `sops`, which writes `secrets/masterkey.enc.yaml` (field `masterkey`, the `.sops.yaml` recipient).
The plaintext never touches the workstation's disk. The script then decrypts that file with the same
command the resign runbook uses and compares its sha256 with the Publisher's copy. It shreds the
Publisher's copy only if they match. It prints no secret values and does not commit.

If it stops partway, you can safely run it again. If the secret already exists, the script only
checks it and then removes the key. If the secret was made from a different key, the script refuses
and leaves both the key and the secret alone.

Then commit the two new files:

```sh
git add secrets/masterkey.enc.yaml ansible/roles/cvmfs_client/files/nix.hayweb.org.pub
git commit -m "Escrow the nix.hayweb.org master key; commit its public key"
```

## 3. Re-run the playbook

```sh
(cd ansible && ansible-playbook playbooks/publisher.yml)
```

The guard now passes, and every step is a no-op or converges. From now on, any run that finds the
master key on the Publisher fails at the guard and names `masterkey-escrow`. The only time the key is
there on purpose is during a resign; pass `-e publisher_allow_masterkey=true` if you must run the
playbook then. Nothing has been published yet, so the union is still deferred on this run.

## 4. First publish, then assemble the union

On the Publisher, run the reconciler once by hand. It publishes `master` to `canary`
(publish/publish.sh), building aarch64 on the Builders:

```sh
sudo systemctl start cvmfs-publish.service
journalctl -u cvmfs-publish.service -e    # ends "published <commit>"
```

The client view sees the publish once the Cache and the repository TTL (240 s) let it through:

```sh
ls /cvmfs-client/nix.hayweb.org/nix/var/nix/db/db.sqlite
readlink /cvmfs-client/nix.hayweb.org/profiles/canary/builder/x86_64-linux
```

Then re-run the playbook. It finds the Lower Store, moves the plain `/nix/store` into the RW Branch,
assembles the union and verifies it (the daemon serves the `builder` Profile through the overlay),
as on any fleet host:

```sh
(cd ansible && ansible-playbook playbooks/publisher.yml)
```

If it still prints "Union deferred", the client view has not seen the publish yet: wait for the TTL
and run it again.

## If the first run fails after mkfs

The repository exists, so the next run will not repeat mkfs, and the guard will stop it. Do step 2,
then re-run.

## The two mounts of the repository

After the first run the Publisher has two mounts of `nix.hayweb.org`:

```sh
findmnt /cvmfs/nix.hayweb.org                # overlay_nix.hayweb.org: cvmfs_server's, for transactions
findmnt /cvmfs-client/nix.hayweb.org         # cvmfs2: the client view, the union store's Lower Store
sudo cvmfs_talk -i nix.hayweb.org host info  # client view: active host is cache1
```

`cvmfs_config probe` checks only `/cvmfs/nix.hayweb.org`, so it reports "Failed!" on the Publisher.
That is expected: that path is the server's overlay. The role probes the client view with
`cvmfs_talk` instead (ADR 0004).

If a run stops at "No client cvmfs mount on the server's /cvmfs/<repo>", an `/etc/fstab` line of
type `cvmfs` targets `/cvmfs/nix.hayweb.org`. An older `cvmfs_client` wrote it. Delete that line,
but keep the two lines marked `# added by CernVM-FS for nix.hayweb.org`. If `findmnt
/cvmfs/nix.hayweb.org` shows `cvmfs2`, run `sudo umount /cvmfs/nix.hayweb.org`. Then run
`sudo cvmfs_server mount nix.hayweb.org` and re-run the playbook.
