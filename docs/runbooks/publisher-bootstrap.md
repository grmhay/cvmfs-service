# Runbook: first run on a fresh Publisher

`cvmfs_server mkfs` creates two keys on the Publisher. The **public key** goes to every host. The
**master key** must not stay on the Publisher: it lives in SOPS and comes back only for a resign
(CLAUDE.md, docs/runbooks/resign.md). This is the one-off sequence that gets both keys where they
belong. Before you start, the Origin bucket must be verified (server/minio/RUNBOOK.md) and
`ansible/secrets/publisher.enc.yaml` must hold the MinIO keys and the builder key
(ansible/secrets/README.md).

The playbook steps normally run as Semaphore template 7 (`cvmfs: publisher`) from the collection
that ansible-lab-config vendors; see [Under Semaphore](#under-semaphore). The non-playbook steps
(escrow, committing the public key, tagging) run from a checkout inside a `nix develop` shell on any
host with the shared age key (ADR 0005); the commands below assume the checkout root. Running the
playbook from such a checkout works too.

## 1. Playbook (creates the repository)

```sh
(cd ansible && ansible-playbook playbooks/publisher.yml)
```

`publisher.yml` runs in this order:

1. `cvmfs_publisher` (tasks `repository`): runs mkfs once, then prints the new public key and its
   sha256 under "Show the repository public key". It writes nothing into the checkout or the
   collection. To also get the key as a file on the control node, pass
   `-e publisher_public_key_fetch_dest=<path>` (step 2).
2. `cvmfs_client` and `nix_union_store`: on the Publisher, `cvmfs_client` uses the key mkfs left in
   `/etc/cvmfs/keys` (`cvmfs_public_key_from_host`, set only by `publisher.yml`) instead of shipping
   the committed one. If a committed key exists and differs, the run fails (see
   [The public key](#the-public-key)). If none is committed yet, it prints a reminder and goes on.
   Then it mounts the client view of the repository at `/cvmfs-client/nix.hayweb.org` (through the Cache). mkfs owns `/cvmfs/nix.hayweb.org` here,
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
into `sops`, which writes `ansible/secrets/masterkey.enc.yaml` (field `masterkey`, the `.sops.yaml` recipient).
The plaintext never touches the workstation's disk. The script then decrypts that file with the same
command the resign runbook uses and compares its sha256 with the Publisher's copy. It shreds the
Publisher's copy only if they match. It prints no secret values and does not commit.

If it stops partway, you can safely run it again. If the secret already exists, the script only
checks it and then removes the key. If the secret was made from a different key, the script refuses
and leaves both the key and the secret alone.

Then put the public key at its home and commit both files. Take the key from the run output, or
fetch it from the Publisher:

```sh
ssh publisher cat /etc/cvmfs/keys/nix.hayweb.org.pub > ansible/roles/cvmfs_client/files/nix.hayweb.org.pub
sha256sum ansible/roles/cvmfs_client/files/nix.hayweb.org.pub   # = the sha256 the run printed
git add ansible/secrets/masterkey.enc.yaml ansible/roles/cvmfs_client/files/nix.hayweb.org.pub
git commit -m "Escrow the nix.hayweb.org master key; commit its public key"
```

From a checkout, step 1 can write the file for you: run it from `ansible/` with
`-e publisher_public_key_fetch_dest=$PWD/roles/cvmfs_client/files/nix.hayweb.org.pub`. Never point
it into a vendored copy of the collection: the next re-vendor wipes it.

Fleet hosts read the key from the collection, so they get it only from a release: see
[The public key](#the-public-key).

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

## The public key

Its one home is `ansible/roles/cvmfs_client/files/nix.hayweb.org.pub` in this repo. That path ships
inside the collection `grmhay.cvmfs_service`, so a checkout and the vendored collection read the same
file. On every host but the Publisher, `cvmfs_client` ships it to `/etc/cvmfs/keys/`. Without it, the
run stops at "The committed repository public key is there", before any copy, and names the fix.

After the key is committed, fleet hosts (templates 8–10, or `clients.yml`/`builders.yml` run from
elsewhere) need a release that contains it:

1. Bump `version:` in `ansible/galaxy.yml`, commit, and tag that commit `v<version>`. Push both.
2. In ansible-lab-config, bump the cvmfs-service pin in `buildhost-all/requirements.yml` to that
   tag, re-vendor and commit (its docs/cvmfs_service_jobs.md, "Rolling the fleet to a new
   cvmfs-service release").

On the Publisher, every run compares the committed key with `/etc/cvmfs/keys/nix.hayweb.org.pub`.
A mismatch fails at "The Publisher's public key matches the committed one". Either the committed
key is for another repository, or the repository was re-created (a second mkfs) and every client
still trusts the old key. Find out which before you change either file.

## Under Semaphore

Template 7 (`cvmfs: publisher`) runs `grmhay.cvmfs_service.publisher` from the collection that
ansible-lab-config vendors. The runner's checkout is thrown away after the run, so the key comes out
through the run output:

1. Run template 7 (step 1). A collection pinned before #17 does not print the key; take it from the
   Publisher instead (`ssh publisher cat /etc/cvmfs/keys/nix.hayweb.org.pub`).
2. Copy the key and its sha256 from "Show the repository public key" in the task output.
3. Here: write it to `ansible/roles/cvmfs_client/files/nix.hayweb.org.pub`, check `sha256sum`
   against the output, and commit it with the escrowed master key (step 2).
4. Tag a release, then bump the pin and re-vendor in ansible-lab-config ([The public
   key](#the-public-key)).
5. Run template 7 again (step 3). It reports "The Publisher's public key matches the committed
   files/nix.hayweb.org.pub". Templates 8–10 can now ship the key.

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
