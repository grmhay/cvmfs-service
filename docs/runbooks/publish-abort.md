# Runbook: a publish failed or hung

Symptoms: `cvmfs-publish.service` failed; `cvmfs_server list` shows the repository "in transaction".

1. Look: `journalctl -u cvmfs-publish.service -n 200` and `cvmfs_server list`.
2. If a transaction is open and nothing is running: `sudo -u publisher cvmfs_server abort -f nix.hayweb.org`.
3. Consistency: `cvmfs_server check nix.hayweb.org` (reads from the Origin; may take a while).
4. The reconciler gates on the last **successful** publish, so the next timer tick retries the same
   revision automatically. To retry now: `systemctl start cvmfs-publish.service`.
5. If the failure was a remote-builder outage, `nix store ping --store ssh://nixbuild@pi5` from the
   Publisher as root; check `pi5`/`pi6` with `ansible/playbooks/builders.yml`.
