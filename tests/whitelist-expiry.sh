#!/bin/sh
# Tests for publish/whitelist-expiry.sh, run against the fixtures in
# tests/fixtures/whitelist/. POSIX sh on purpose: `nix flake check` runs this
# under busybox only, the same userland as the probe container on skyline.
#
# Expected values are literals worked out with GNU date, not recomputed here:
#   date -u -d '2026-11-25 12:00:00' +%s  -> 1795608000
#   date -u -d '2024-02-29 23:59:59' +%s  -> 1709251199
#
# Usage: sh tests/whitelist-expiry.sh   (from the checkout root, or set ROOT)
set -u

root="${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
parser="$root/publish/whitelist-expiry.sh"
fixtures="$root/tests/fixtures/whitelist"

# 2026-11-05T12:00:00Z: 20 days before the fixture's expiry.
now=1793880000
failures=0

# expect <name> <fixture> <exit code> <exact stdout>
expect() {
  name="$1" fixture="$2" want_rc="$3" want_out="$4"
  got_out="$(NOW="$now" sh "$parser" < "$fixture")"
  got_rc=$?
  if [ "$got_rc" = "$want_rc" ] && [ "$got_out" = "$want_out" ]; then
    printf 'ok   %s\n' "$name"
  else
    printf 'FAIL %s\n  want rc=%s out=%s\n  got  rc=%s out=%s\n' \
      "$name" "$want_rc" "$want_out" "$got_rc" "$got_out"
    failures=$((failures + 1))
  fi
}

expect "a signed whitelist reports its expiry and the days left" \
  "$fixtures/valid" 0 \
  "status=ok expires=2026-11-25T12:00:00Z expires_epoch=1795608000 days_left=20.0"

expect "an empty response is an error, not a pass" \
  "$fixtures/empty" 1 "status=error reason=no_expiry"

expect "an HTML error page in place of the whitelist is an error" \
  "$fixtures/html-404" 1 "status=error reason=no_expiry"

expect "an expiry that is not a real date is an error" \
  "$fixtures/bad-date" 1 "status=error reason=bad_expiry"

expect "a whitelist cut off inside the expiry line is an error" \
  "$fixtures/truncated" 1 "status=error reason=bad_expiry"

expect "an E line in the signed part is not taken for the expiry" \
  "$fixtures/expiry-only-after-separator" 1 "status=error reason=no_expiry"

# 12 hours after 2024-02-29T23:59:59Z.
now=1709294399
expect "an expired whitelist reports negative days left (leap day)" \
  "$fixtures/expired-leap-day" 0 \
  "status=ok expires=2024-02-29T23:59:59Z expires_epoch=1709251199 days_left=-0.5"

[ "$failures" -eq 0 ] || { printf '%s test(s) failed\n' "$failures"; exit 1; }
echo "all passed"
