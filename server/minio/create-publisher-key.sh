#!/usr/bin/env bash
# Create the Publisher's MinIO service account (server/minio/RUNBOOK.md §2) and
# write its keys, encrypted, to ansible/secrets/publisher.enc.yaml. The secret key goes
# from mc's JSON output through pipes into sops: it is never printed or written
# to disk in plain text.
#
# Usage, in a `nix develop` shell after `mc alias set`:
#   server/minio/create-publisher-key.sh <mc alias> <root user>
set -euo pipefail

usage="usage: $0 <mc alias> <root user>"
mc_alias="${1:?$usage}"
owner="${2:?$usage}"
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
policy=server/minio/publisher-policy.json
out=ansible/secrets/publisher.enc.yaml

if [ -e "$out" ]; then
  echo "$out already exists; add keys to it with sops --set instead" >&2
  exit 1
fi

created="$(mc admin user svcacct add "$mc_alias" "$owner" \
  --name cvmfs-publisher --description "CVMFS Publisher, bucket cvmfs only" \
  --policy "$policy" --json)"

orphaned() { # <reason>
  echo "$1; nothing was written. If mc created the account, remove it and run again:" >&2
  echo "  mc admin user svcacct ls $mc_alias $owner      # find cvmfs-publisher" >&2
  echo "  mc admin user svcacct rm $mc_alias <access key>" >&2
  exit 1
}

if ! printf '%s' "$created" | jq -e '.accessKey and .secretKey' >/dev/null; then
  orphaned "mc did not return a key pair"
fi
access_key="$(printf '%s' "$created" | jq -r .accessKey)"

tmp="$(mktemp "$out.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
if ! printf '%s' "$created" \
    | jq -r '"minio_access_key: \(.accessKey | @json)\nminio_secret_key: \(.secretKey | @json)"' \
    | sops encrypt --filename-override "$out" >"$tmp"; then
  orphaned "encrypting the keys failed"
fi
# The encrypted copy is the only one: keep it if the rename fails.
trap - EXIT
mv "$tmp" "$out" || { echo "could not rename $tmp to $out; rename it by hand" >&2; exit 1; }
echo "created service account $access_key; keys encrypted in $out"
