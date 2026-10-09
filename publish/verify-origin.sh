#!/usr/bin/env bash
# Verify the Origin (MinIO) and the Cache from wherever this runs: TLS chain,
# anonymous GET on the bucket, and the manifest through the Cache. The roles
# only VERIFY the bucket — it is created by hand (server/minio/RUNBOOK.md).
#
# Env: CVMFS_REPOSITORY; MINIO_URL (https://minio.hayweb.org:<api-port>);
#      CACHE_URL (http://cache1.hayweb.org); BUCKET (cvmfs)
set -euo pipefail

repo="${CVMFS_REPOSITORY:?}"
minio="${MINIO_URL:-https://minio.hayweb.org:9000}"
cache="${CACHE_URL:-http://cache1.hayweb.org}"
bucket="${BUCKET:-cvmfs}"
fail=0

check() { # <label> <command...>
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then printf 'ok    %s\n' "$label"; else printf 'FAIL  %s\n' "$label"; fail=1; fi
}

host="${minio#https://}"; host="${host%%/*}"
check "TLS chain verifies for $host" \
  bash -c "openssl s_client -connect '$host' -servername '${host%%:*}' </dev/null 2>/dev/null | grep -q 'Verify return code: 0'"
check "anonymous GET of .cvmfspublished from the bucket" \
  curl -fsS "$minio/$bucket/$repo/.cvmfspublished" -o /dev/null
check "anonymous LIST is refused (policy is GetObject only)" \
  bash -c "! curl -fsS '$minio/$bucket/' -o /dev/null"
check "manifest through the cache" \
  curl -fsS "$cache/cvmfs/$repo/.cvmfspublished" -o /dev/null
check "cache serves the whitelist" \
  curl -fsS "$cache/cvmfs/$repo/.cvmfswhitelist" -o /dev/null

exit "$fail"
