# Runbook: re-sign the whitelist

The repository whitelist expires 30 days after signing; clients refuse an expired one. The timer
`cvmfs-resign.timer` fires on the 1st and 15th but can only sign if the master key is present —
and it is deliberately **not** kept on the Publisher (secrets/README.md).

Every ~3 weeks, from a `nix develop` shell:

```sh
sops --decrypt secrets/masterkey.enc.yaml | yq '.masterkey' \
  | ssh publisher 'sudo install -m 0400 /dev/stdin /etc/cvmfs/keys/nix.hayweb.org.masterkey'
ssh publisher 'sudo cvmfs_server resign nix.hayweb.org && sudo shred -u /etc/cvmfs/keys/nix.hayweb.org.masterkey'
curl -s http://cache1.hayweb.org/cvmfs/nix.hayweb.org/.cvmfswhitelist | head -3   # new expiry
```

Follow-up: automate by letting the resign unit fetch the key via `sops` with an age key scoped to
this one secret, once the Publisher is trusted with it.
