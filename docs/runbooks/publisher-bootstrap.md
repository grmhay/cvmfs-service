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
2. `cvmfs_client` and `nix_union_store`: ship that key, mount the repository and assemble the
   union store.
3. `cvmfs_publisher` (tasks `publishing`): sets up the builders and the clone, then installs the
   resign and publish timers.

On this run the master key is still on the Publisher. The guard ("Master key is not on the
Publisher") lets the run that created the repository finish, and the last task prints a reminder.

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
playbook then.

## If the first run fails after mkfs

The repository exists, so the next run will not repeat mkfs, and the guard will stop it. Do step 2,
then re-run.
