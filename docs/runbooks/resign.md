# Runbook: re-sign the whitelist

The repository whitelist expires 30 days after signing; clients refuse an expired one. The
Publisher re-signs it unattended (#19): `cvmfs-resign.timer` fires weekly (Monday 03:00,
`Persistent=true`), which gives four tries inside the 30 days.

## How the unattended resign works

`cvmfs-resign.service` runs `/usr/local/sbin/cvmfs-resign` (the role's
`files/cvmfs-resign.sh`) as root:

1. It takes the publish reconciler's lock (`publisher_lock_file`,
   `~publisher/.local/state/cvmfs-publish/publish.lock`) and holds it to the end, so a resign never
   lands inside a publish transaction. If a publish is running it waits up to
   `publisher_resign_lock_wait` (3.5 h) and then fails without decrypting anything; while it holds
   the lock the reconciler skips its 5-minute tick. A transaction opened **by hand** (outside
   `cvmfs-publish.service`) does not take the lock, so don't leave one open over the Monday 03:00 run.
2. It reads the escrowed ciphertext `/etc/cvmfs-resign/masterkey.enc.yaml` (root only). The role
   installs it from the collection's `secrets/masterkey.enc.yaml` once that exists.
3. `sops` decrypts the `masterkey` field with the shared age key on `/shared` (ADR 0005), run as
   `publisher_resign_sops_user` (`ansible`) because the export may squash root. The unit has
   `RequiresMountsFor=` on the key file.
4. The plaintext goes only into the unit's `RuntimeDirectory`, `/run/cvmfs-resign` (tmpfs, 0700).
   `/etc/cvmfs/keys/nix.hayweb.org.masterkey` becomes a **symlink** to it, because `cvmfs_server`
   reads the key at that fixed path.
5. `cvmfs_server resign nix.hayweb.org` signs a new 30-day whitelist and uploads it to the Origin.
6. On success **and** on failure, the wrapper removes the symlink and shreds the tmpfs copy.
   `ExecStopPost` (`cvmfs-resign cleanup`) repeats that after a kill or a timeout, and systemd removes
   the runtime dir when the unit stops. The master key is never at rest in plaintext.

The wrapper removes only its own symlink (one into its runtime dir). It never touches a **regular
file** at the key path: if it finds one (escrow not finished, or a resign by hand in progress), it
fails and leaves the file alone. A symlink to anywhere else fails the same way, naming its target.

Before escrow (no `masterkey.enc.yaml`), the unit fails and names `masterkey-escrow`. To fix that, do
`docs/runbooks/publisher-bootstrap.md` step 2, release, and re-run `publisher.yml`.

## Check it

```sh
ssh publisher 'systemctl list-timers cvmfs-resign.timer; journalctl -u cvmfs-resign.service -n 20 --no-pager'
curl -s http://cache1.hayweb.org/cvmfs/nix.hayweb.org/.cvmfswhitelist | head -3   # line 2: E<expiry>
ssh publisher 'ls -la /etc/cvmfs/keys/ /run/cvmfs-resign 2>&1'                      # no .masterkey
```

To resign now: `ssh publisher 'sudo systemctl start cvmfs-resign.service'`. Failures land in the
journal, and from there in Loki. The whitelist expiry alert (#20) catches a resign that keeps failing.

A playbook run during a resign passes the master-key guard: the guard ignores a symlink into
`/run/cvmfs-resign/` (`tasks/masterkey_guard.yml`).

## Break-glass: resign by hand

Use this only when the unit cannot work, for example `/shared` is down or the age key is not
readable on the Publisher. From a `nix develop` shell at the checkout root on a host with the age key:

```sh
sops --decrypt --extract '["masterkey"]' ansible/secrets/masterkey.enc.yaml \
  | ssh publisher 'sudo install -m 0400 /dev/stdin /etc/cvmfs/keys/nix.hayweb.org.masterkey'
ssh publisher 'sudo cvmfs_server resign nix.hayweb.org && sudo shred -u /etc/cvmfs/keys/nix.hayweb.org.masterkey'
curl -s http://cache1.hayweb.org/cvmfs/nix.hayweb.org/.cvmfswhitelist | head -3   # new expiry
```

The key streams through the pipe and never lands on the workstation's disk. `--extract` prints the
key exactly as `masterkey-escrow` verified it (sha256 against the Publisher's copy).

While that regular file is on the Publisher, `ansible/playbooks/publisher.yml` fails at "Master key
is not on the Publisher", and the timer's resign refuses to run. Finish the resign and shred first.
If you really must run the playbook in that window, pass `-e publisher_allow_masterkey=true`.

If the shred step did not run (for example, the resign failed), remove the key by hand before you leave:
`ssh publisher 'sudo shred -u /etc/cvmfs/keys/nix.hayweb.org.masterkey'`. The copy in SOPS is
unchanged, so there is nothing to escrow again.

## Expiry alert

Grafana on skyline alerts before the whitelist runs out, so a resign that keeps failing gets noticed
(#20). The alert lives in homelab-opscontrolplane, not in this collection:

- **Probe:** the `cvmfs-whitelist-probe` stack on skyline fetches
  `http://cache1.hayweb.org/cvmfs/nix.hayweb.org/.cvmfswhitelist` every 15 minutes, the way clients
  see it, and logs one logfmt line: `status=ok expires=… expires_epoch=… days_left=…`, or
  `status=error reason=fetch_failed|no_expiry|bad_expiry`. alloy ships the line to pi2's Loki.
- **Parser:** `publish/whitelist-expiry.sh` here. The probe runs a vendored copy, so if you change
  the parser, copy it to `environments/prod/cvmfs-whitelist-probe/whitelist-expiry.sh` in the ops repo.
  Its tests are `tests/whitelist-expiry.sh` and run with busybox under `nix flake check`.
- **Rules:** `environments/prod/grafana/provisioning/alerting/cvmfs-whitelist.yaml` in the ops repo,
  folder `cvmfs`:
  - *CVMFS whitelist expires in under 10 days*: the lowest `days_left` of the last hour is under 10.
  - *CVMFS whitelist probe has no good reading*: no `status=ok` line in the last hour. It fires on a
    missing or unparsable whitelist, a failed fetch, a stopped probe and a Loki error. No data counts
    as a failure.

With a weekly timer and a 30-day whitelist, the expiry alert fires after two weekly resigns in a row
have failed, with at least one try left. When it fires, read the timer's last runs ("Check it"), fix the
cause and start the unit, or resign by hand (break-glass). When the probe alert fires, the probe's own lines say why:
`{container="cvmfs-whitelist-probe"}` in Grafana Explore. Check the expiry by hand from a `nix develop` shell:

```sh
curl -s http://cache1.hayweb.org/cvmfs/nix.hayweb.org/.cvmfswhitelist | nix run .#whitelist-expiry
```

The `E` line holds the expiry (UTC). It is the second line, before the `N<repository>` line, not after it.
