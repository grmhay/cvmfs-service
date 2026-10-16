#!/usr/bin/env bash
# Spike S3: the scratch bucket `cvmfs-spike` and its scratch service account,
# made the same way as the real ones (server/minio/RUNBOOK.md §2) but never
# touching bucket `cvmfs`. Run by hand, in a `nix develop` shell, after
# `mc alias set` with the root user (MinIO admin stays a human step).
#
#   s3-scratch-bucket.sh create <mc alias> <root user> <ssh target of the spike VM>
#   s3-scratch-bucket.sh delete <mc alias> <root user>
#
# create: bucket + the anonymous GetObject policy + a service account with the
# publisher policy, both rewritten from `cvmfs` to `cvmfs-spike`. The keys go
# from mc's JSON through ssh into /root/s3-spike.keys (0600) on the VM; they
# are never printed or written on this machine.
# delete: removes the service account and the bucket with everything in it.
set -euo pipefail

usage="usage: $0 create <mc alias> <root user> <ssh target> | delete <mc alias> <root user>"
action="${1:?$usage}"
mc_alias="${2:?$usage}"
owner="${3:?$usage}"
cd "$(dirname "${BASH_SOURCE[0]}")/.."
bucket=cvmfs-spike
account=cvmfs-spike

# Without the alias, mc treats "<alias>/cvmfs-spike" as a local directory.
if ! mc alias list "$mc_alias" >/dev/null 2>&1; then
  echo "no mc alias $mc_alias; run: mc alias set $mc_alias https://minio.hayweb.org:9000" >&2
  exit 1
fi

# The real policies, pointed at the scratch bucket.
scratch_policy() { # <policy file>
  sed 's#arn:aws:s3:::cvmfs\([/"]\)#arn:aws:s3:::'"$bucket"'\1#g' "$1"
}

case "$action" in
  create)
    target="${4:?$usage}"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    scratch_policy server/minio/bucket-policy.json >"$tmp/bucket.json"
    scratch_policy server/minio/publisher-policy.json >"$tmp/publisher.json"
    if grep -q 'arn:aws:s3:::cvmfs[/"]' "$tmp"/*.json; then
      echo "a policy still names bucket cvmfs; refusing" >&2; exit 1
    fi

    mc mb "$mc_alias/$bucket"
    mc anonymous set-json "$tmp/bucket.json" "$mc_alias/$bucket"
    mc admin user svcacct add "$mc_alias" "$owner" \
        --name "$account" --description "CVMFS spike S3, bucket $bucket only; delete after" \
        --policy "$tmp/publisher.json" --json \
      | jq -r '.accessKey, .secretKey' \
      | ssh "$target" 'sudo install -m 0600 /dev/stdin /root/s3-spike.keys && sudo wc -l /root/s3-spike.keys'
    echo "bucket $bucket and account $account created; keys are in $target:/root/s3-spike.keys"
    ;;
  delete)
    mc admin user svcacct ls "$mc_alias" "$owner" --json \
      | jq -r --arg n "$account" 'select(.name == $n) | .accessKey' \
      | while read -r key; do mc admin user svcacct rm "$mc_alias" "$key"; done
    mc rb --force "$mc_alias/$bucket"
    ;;
  *) echo "$usage" >&2; exit 2 ;;
esac
