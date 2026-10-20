# Runbook: re-sign the whitelist

The repository whitelist expires 30 days after signing; clients refuse an expired one. The timer
`cvmfs-resign.timer` fires on the 1st and 15th but can only sign if the master key is present —
and it is deliberately **not** kept on the Publisher (secrets/README.md).

The key lives in `secrets/masterkey.enc.yaml` under the `masterkey` field. It gets there once, after
the Publisher's first playbook run, through `nix run .#masterkey-escrow`
(docs/runbooks/publisher-bootstrap.md). If that file does not exist yet, do that first.

Every ~3 weeks, from a `nix develop` shell at the checkout root:

```sh
sops --decrypt --extract '["masterkey"]' secrets/masterkey.enc.yaml \
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
