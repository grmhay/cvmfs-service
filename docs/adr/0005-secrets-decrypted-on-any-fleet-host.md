# 0005 — Secrets are decrypted on any fleet host with the shared age key

Status: accepted (2026-10-23). Amends decision Q12 of `plans/0001-nix-over-cvmfs.md`.

## Context

Q12 put every secret in SOPS under one age recipient shared with homelab-opscontrolplane, and only
the workstation held the private key. That made every job that needs a secret a workstation job:
Semaphore template 7 (`cvmfs: publisher`) failed at "Decrypt publisher secrets" (ansible-lab-config
task #213, 2026-10-21), and the whitelist resign needed a person every ~3 weeks. Neither is
acceptable for a repeated production job.

The homelab now installs `sops` and `age` on every non-Proxmox host as standard. Each host's
`~/.config/sops/age/keys.txt` (for the `ansible`, `grmhay` and `pi` users) links to
`/shared/ansible-config/sops/age/keys.txt` on filer1's NFS export (group `sopsusers`, mode 0640),
which holds the Q12 recipient's identity.

## Decision

- The ciphertext lives in `ansible/secrets/` and ships inside the collection, so the vendored
  collection and a checkout read the same files. `publisher_secrets_file` is relative to the role.
- The control node decrypts with `SOPS_AGE_KEY_FILE` set from `sops_age_key_file`, which defaults to
  the control user's real `~/.config/sops/age/keys.txt` (from the passwd entry). Semaphore gives
  each template its own `HOME`, so the sops default would miss the key.
- Semaphore template 7 is the normal way to run `publisher.yml`. No step that repeats depends on a
  workstation. The Publisher can decrypt too, which #19 uses for an unattended resign.

## Consequences

- One key decrypts every secret encrypted to the Q12 recipient, in this repo and in
  homelab-opscontrolplane, and every fleet host can read it.
- The export is `sec=sys`: filer1 trusts the user ID a client claims, and root on a client can
  read the key. Any machine that can mount the export with root can therefore read every secret.
  Restricting the export to fleet addresses limits that; Kerberos (`sec=krb5`) or per-host age
  identities would remove it, and are the upgrade path if that trust is not wanted.
- Secrets depend on `/shared` being mounted. The mount is `soft`, so a filer1 outage fails a
  decrypt with an I/O error rather than hanging it. The whitelist expiry alert (#20) catches a
  resign that keeps failing.
- Revoking a host's access means rotating the shared key and re-encrypting everything for the new
  recipient.
