#!/usr/bin/env bash
# Unattended whitelist resign, run as root by cvmfs-resign.service (issue #19).
# Installed by the cvmfs_publisher role; the whitelist expires 30 days after
# signing and clients then refuse the Repository (docs/runbooks/resign.md).
#
#   cvmfs-resign            decrypt the escrowed master key, resign, remove the key
#   cvmfs-resign cleanup    remove what a killed run left (the unit's ExecStopPost)
#
# The plaintext master key only ever lives in the unit's RuntimeDirectory
# (tmpfs under /run, 0700). cvmfs_server reads it at the fixed path
# /etc/cvmfs/keys/<repo>.masterkey, so that path is a symlink into the
# runtime dir for the length of the resign, and is removed on success and on
# failure. A regular file at that path is never touched: it is either the
# key mkfs left before escrow, or a break-glass resign by hand.
#
# Environment (set by the unit):
#   CVMFS_REPOSITORY    repository name (required)
#   RUNTIME_DIRECTORY   tmpfs work dir, from RuntimeDirectory= (required)
#   RESIGN_SECRET       masterkey.enc.yaml on this host (default /etc/cvmfs-resign/masterkey.enc.yaml)
#   RESIGN_MASTERKEY    where cvmfs_server looks (default /etc/cvmfs/keys/<repo>.masterkey)
#   SOPS_AGE_KEY_FILE   the shared age identity on /shared (ADR 0005)
#   RESIGN_SOPS_USER    run sops as this user (one that can read SOPS_AGE_KEY_FILE
#                       on the NFS export); empty: run it as root
set -euo pipefail

repo="${CVMFS_REPOSITORY:?}"
run="${RUNTIME_DIRECTORY:?set by systemd from RuntimeDirectory=}"
secret="${RESIGN_SECRET:-/etc/cvmfs-resign/masterkey.enc.yaml}"
key="${RESIGN_MASTERKEY:-/etc/cvmfs/keys/$repo.masterkey}"
sops_user="${RESIGN_SOPS_USER:-}"
plain="$run/masterkey"

log() { printf 'cvmfs-resign[%s]: %s\n' "$repo" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# Remove our symlink and shred the tmpfs copy. Fails if a link is still there.
cleanup() {
  if [ -L "$key" ]; then rm -f "$key"; fi
  if [ -e "$plain" ]; then shred -u "$plain"; fi
  if [ -L "$key" ] || [ -e "$plain" ]; then
    log "ERROR: could not remove the master key ($key -> $plain)"
    return 1
  fi
}

# Ciphertext on stdin, key on stdout. sops reads stdin itself (no filename),
# so it works as an unprivileged user on a file only root can open.
decrypt() {
  local cmd=(sops decrypt --input-type yaml --extract '["masterkey"]')
  if [ -n "$sops_user" ]; then
    runuser -u "$sops_user" -- env SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-}" "${cmd[@]}"
  else
    "${cmd[@]}"
  fi
}

if [ "${1:-}" = cleanup ]; then
  cleanup
  exit
fi

[ -f "$secret" ] || die "no $secret: the master key has not been escrowed yet. Run \`nix run .#masterkey-escrow\` (docs/runbooks/publisher-bootstrap.md), commit ansible/secrets/masterkey.enc.yaml, release, and re-run publisher.yml"

if [ -L "$key" ]; then
  log "removing a stale $key symlink (a run that was killed)"
  rm -f "$key"
fi
[ ! -e "$key" ] || die "a master key is already at $key (escrow not finished, or a resign by hand in progress): leaving it; see docs/runbooks/resign.md"

trap 'cleanup || exit 1' EXIT
umask 077

decrypt < "$secret" > "$plain" || die "could not decrypt the master key from $secret (is /shared mounted, and ${SOPS_AGE_KEY_FILE:-the age key} readable${sops_user:+ by $sops_user}?)"
[ -s "$plain" ] || die "$secret decrypted to an empty master key"
ln -s "$plain" "$key"

cvmfs_server resign "$repo" || die "cvmfs_server resign $repo failed"
log "whitelist re-signed"
