#!/usr/bin/env bash
# Verify the Origin (MinIO) and the Cache from wherever this runs: TLS chain,
# anonymous GET on the bucket, and the manifest through the Cache. The roles
# only VERIFY the bucket — it is created by hand (server/minio/RUNBOOK.md).
#
# Env: CVMFS_REPOSITORY; MINIO_URL (https://minio.hayweb.org:9000);
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

# The S3 error code of an anonymous GET, e.g. NoSuchKey or AccessDenied.
s3_code() { # <url>
  curl -s "$1" | sed -n 's:.*<Code>\([^<]*\)</Code>.*:\1:p'
}

host="${minio#https://}"; host="${host%%/*}"
check "TLS chain verifies for $host" \
  bash -c "openssl s_client -connect '$host' -servername '${host%%:*}' </dev/null 2>/dev/null | grep -q 'Verify return code: 0'"
# MinIO answers AccessDenied to anonymous requests for a bucket that does not
# exist as well as for one without the policy. NoSuchKey for a missing object
# proves both the bucket and the anonymous-GET policy, before any repository
# is published.
check "anonymous GET allowed on $bucket (missing object is NoSuchKey)" \
  test "$(s3_code "$minio/$bucket/.verify-origin-probe")" = NoSuchKey
# Meaningful only together with the check above: on its own it also passes
# when the bucket is missing.
check "anonymous LIST is refused (policy is GetObject only)" \
  test "$(s3_code "$minio/$bucket/")" = AccessDenied
check "anonymous GET of .cvmfspublished from the bucket" \
  curl -fsS "$minio/$bucket/$repo/.cvmfspublished" -o /dev/null
check "manifest through the cache" \
  curl -fsS "$cache/cvmfs/$repo/.cvmfspublished" -o /dev/null
check "cache serves the whitelist" \
  curl -fsS "$cache/cvmfs/$repo/.cvmfswhitelist" -o /dev/null

exit "$fail"
