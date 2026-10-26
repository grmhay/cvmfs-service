# Runbook: re-sign the whitelist

The repository whitelist expires 30 days after signing; clients refuse an expired one. The timer
`cvmfs-resign.timer` fires on the 1st and 15th but can only sign if the master key is present —
and it is deliberately **not** kept on the Publisher (ansible/secrets/README.md).

The key lives in `ansible/secrets/masterkey.enc.yaml` under the `masterkey` field. It gets there once, after
the Publisher's first playbook run, through `nix run .#masterkey-escrow`
(docs/runbooks/publisher-bootstrap.md). If that file does not exist yet, do that first.

Every ~3 weeks, from a `nix develop` shell at the checkout root:

```sh
sops --decrypt --extract '["masterkey"]' ansible/secrets/masterkey.enc.yaml \
  | ssh publisher 'sudo install -m 0400 /dev/stdin /etc/cvmfs/keys/nix.hayweb.org.masterkey'
ssh publisher 'sudo cvmfs_server resign nix.hayweb.org && sudo shred -u /etc/cvmfs/keys/nix.hayweb.org.masterkey'
curl -s http://cache1.hayweb.org/cvmfs/nix.hayweb.org/.cvmfswhitelist | head -3   # new expiry
```

The key streams through the pipe and never lands on the workstation's disk. `--extract` prints the
key exactly as `masterkey-escrow` verified it (sha256 against the Publisher's copy).

While the key is on the Publisher, `ansible/playbooks/publisher.yml` fails at "Master key is not on the
Publisher". Finish the resign and shred first. If you really must run the playbook in that window, pass
`-e publisher_allow_masterkey=true`.

If the shred step did not run (for example, the resign failed), remove the key by hand before you leave:
`ssh publisher 'sudo shred -u /etc/cvmfs/keys/nix.hayweb.org.masterkey'`. The copy in SOPS is
unchanged, so there is nothing to escrow again.

Follow-up: automate by letting the resign unit fetch the key via `sops` with an age key scoped to
this one secret, once the Publisher is trusted with it.

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

When the expiry alert fires, re-sign as above and check the timer's last run on the Publisher:
`journalctl -u cvmfs-resign.service`. When the probe alert fires, the probe's own lines say why:
`{container="cvmfs-whitelist-probe"}` in Grafana Explore. Check the expiry by hand from a `nix develop` shell:

```sh
curl -s http://cache1.hayweb.org/cvmfs/nix.hayweb.org/.cvmfswhitelist | nix run .#whitelist-expiry
```

The `E` line holds the expiry (UTC). It is the second line, before the `N<repository>` line, not after it.