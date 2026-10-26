#!/bin/sh
# Read a Repository whitelist (.cvmfswhitelist) on stdin and print its expiry
# as one logfmt line, for the expiry alert (#20) and for a quick check by hand:
#
#   curl -s http://cache1.hayweb.org/cvmfs/nix.hayweb.org/.cvmfswhitelist \
#     | nix run .#whitelist-expiry
#
# The whitelist header is text: the signing time, then `E<YYYYMMDDhhmmss>`
# (the expiry, UTC), then `N<repository>`, then fingerprints, ending at `--`.
# The signed hash and a binary signature follow; nothing after `--` is read.
#
#   status=ok expires=<ISO 8601 UTC> expires_epoch=<s> days_left=<d.d>   exit 0
#   status=error reason=<no_expiry|bad_expiry>                           exit 1
#
# An expired whitelist is still status=ok, with days_left negative.
#
# POSIX sh + awk only, no GNU date: the probe container on skyline runs this
# under busybox. Env: NOW (epoch seconds, defaults to the current time).
set -eu

now="${NOW:-$(date +%s)}"

awk -v now="$now" '
  # Days since 1970-01-01 for a proleptic Gregorian date (H. Hinnant).
  function days_from_civil(y, m, d,   era, yoe, doy, doe) {
    y -= (m <= 2)
    era = int((y >= 0 ? y : y - 399) / 400)
    yoe = y - era * 400
    doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
    doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
    return era * 146097 + doe - 719468
  }
  function days_in_month(y, m) {
    if (m == 2) return (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) ? 29 : 28
    return (m == 4 || m == 6 || m == 9 || m == 11) ? 30 : 31
  }
  $0 == "--" { exit }
  /^E/ && !seen { seen = 1; expiry = substr($0, 2) }
  END {
    if (!seen) { print "status=error reason=no_expiry"; exit 1 }
    y = substr(expiry, 1, 4) + 0; mo = substr(expiry, 5, 2) + 0
    d = substr(expiry, 7, 2) + 0;  h = substr(expiry, 9, 2) + 0
    mi = substr(expiry, 11, 2) + 0; s = substr(expiry, 13, 2) + 0
    if (length(expiry) != 14 || expiry ~ /[^0-9]/ || mo < 1 || mo > 12 ||
        d < 1 || d > days_in_month(y, mo) || h > 23 || mi > 59 || s > 59) {
      print "status=error reason=bad_expiry"; exit 1
    }
    epoch = ((days_from_civil(y, mo, d) * 24 + h) * 60 + mi) * 60 + s
    printf "status=ok expires=%04d-%02d-%02dT%02d:%02d:%02dZ expires_epoch=%d days_left=%.1f\n",
      y, mo, d, h, mi, s, epoch, (epoch - now) / 86400
  }
'
