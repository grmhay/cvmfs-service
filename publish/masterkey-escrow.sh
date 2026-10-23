#!/usr/bin/env bash
# Masterkey escrow: move the Repository master key that `cvmfs_server mkfs`
# leaves on the Publisher into ansible/secrets/masterkey.enc.yaml (SOPS + age, the
# recipient in .sops.yaml), then remove it from the Publisher. Run by hand
# from the checkout root on the workstation, in a `nix develop` shell, after
# the first run of ansible/playbooks/publisher.yml
# (docs/runbooks/publisher-bootstrap.md). Unlike the other scripts here it
# does not run on the Publisher.
#
# The key streams ssh -> sops through a pipe, so the plaintext never touches
# this machine's disk. The Publisher's copy is shredded only after the
# encrypted file decrypts, with the command docs/runbooks/resign.md uses, to a
# key whose sha256 matches the Publisher's. If the secret already exists, the
# script only verifies and removes, so a run that died before the delete can
# be repeated. Prints no secret values and commits nothing.
#
# Usage: masterkey-escrow.sh
#   PUBLISHER_HOST       ssh destination of the Publisher (default: publisher)
#   PUBLISHER_MASTERKEY  key path on the Publisher (default: /etc/cvmfs/keys/<repo>.masterkey)
set -euo pipefail

repo="${CVMFS_REPOSITORY:?}"
host="${PUBLISHER_HOST:-publisher}"
flake="${PUBLISH_FLAKE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
remote_key="${PUBLISHER_MASTERKEY:-/etc/cvmfs/keys/$repo.masterkey}"
secret_rel="ansible/secrets/masterkey.enc.yaml"
secret="$flake/$secret_rel"

log() { printf '%s masterkey-escrow[%s]: %s\n' "$(date -Is)" "$repo" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

[ -f "$flake/.sops.yaml" ] || die "no .sops.yaml in $flake; run from the checkout root"

# One quoted path for every remote command; ssh joins its arguments into a
# shell command line on the Publisher.
q="$(printf '%q' "$remote_key")"
on_publisher() { ssh -o BatchMode=yes "$host" "$@"; }

rc=0
on_publisher "sudo test -f $q" || rc=$?
case "$rc" in
  0) ;;
  255) die "cannot reach $host over ssh" ;;
  *)
    [ -f "$secret" ] || die "no master key at $host:$remote_key and no $secret_rel"
    log "no master key on $host and $secret_rel exists; nothing to do"
    exit 0 ;;
esac

if [ -e "$secret" ]; then
  log "$secret_rel exists; verifying it against $host before removing the key"
else
  log "encrypting $host:$remote_key into $secret_rel"
  # Only ciphertext is ever written here; it is renamed into place once sops
  # has succeeded.
  tmp="$(mktemp "$secret.XXXXXX")"
  trap 'rm -f "$tmp"' EXIT
  on_publisher "sudo cat $q" \
    | { printf 'masterkey: |\n'; sed 's/^/  /'; } \
    | sops --config "$flake/.sops.yaml" encrypt \
        --filename-override "$secret_rel" --output "$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$secret"
  trap - EXIT
fi

want="$(on_publisher "sudo sha256sum $q" | cut -d' ' -f1)"
got="$(sops --decrypt --extract '["masterkey"]' "$secret" | sha256sum | cut -d' ' -f1)"
[ -n "$want" ] || die "could not hash the key on $host; key left in place"
[ "$got" = "$want" ] || die "$secret_rel does not decrypt to the key on $host; key left in place, secret untouched"
log "$secret_rel decrypts to the key on $host (sha256 match)"

on_publisher "sudo shred -u $q"
if on_publisher "sudo test -e $q"; then die "$host:$remote_key still exists after shred"; fi
log "removed $remote_key from $host"
log "next: review and commit $secret_rel (this script does not commit), then re-run the playbook"
