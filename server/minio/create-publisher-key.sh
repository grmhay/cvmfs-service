#!/usr/bin/env bash
# Create the Publisher's MinIO service account (server/minio/RUNBOOK.md §2) and
# write its keys, encrypted, to secrets/publisher.enc.yaml. The secret key goes
# from mc's JSON output straight into sops: it is never printed or written to
# disk in plain text.
#
# Usage, from the repo root in a `nix develop` shell, after `mc alias set`:
#   server/minio/create-publisher-key.sh <mc alias> <root user>
set -euo pipefail

alias="${1:?usage: $0 <mc alias> <root user>}"
owner="${2:?usage: $0 <mc alias> <root user>}"
policy=server/minio/publisher-policy.json
out=secrets/publisher.enc.yaml

if [ -e "$out" ]; then
  echo "$out already exists; add keys to it with sops --set instead" >&2
  exit 1
fi

created="$(mc admin user svcacct add "$alias" "$owner" \
  --name cvmfs-publisher --description "CVMFS Publisher, bucket cvmfs only" \
  --policy "$policy" --json)"

access_key="$(jq -r '.accessKey // empty' <<<"$created")"
if [ -z "$access_key" ] || ! jq -e '.secretKey // empty' <<<"$created" >/dev/null; then
  echo "mc did not return a key pair; nothing was written" >&2
  exit 1
fi

tmp="$(mktemp "$out.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
if ! jq -r '"minio_access_key: \(.accessKey | @json)\nminio_secret_key: \(.secretKey | @json)"' \
    <<<"$created" | sops encrypt --filename-override "$out" >"$tmp"; then
  echo "encrypting failed; remove the account and run again:" >&2
  echo "  mc admin user svcacct rm $alias $access_key" >&2
  exit 1
fi
mv "$tmp" "$out"
trap - EXIT
echo "created service account $access_key; keys encrypted in $out"
