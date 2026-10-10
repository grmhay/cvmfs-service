#!/usr/bin/env bash
# Checks a Union Store host after the nix_union_store role upgraded Nix (#12).
# Run as root on the host:
#
#   union-upgrade-check.sh <nix-version> <lower-path> [rw-path...]
#
# <nix-version> is the upstream Nix the pinned installer installs (e.g. 2.35.2).
# <lower-path> is a store path only the Lower Store has (with a stand-in, one
# that spikes/union-standin.sh printed). Each <rw-path> is a store path in the
# RW Branch from before the upgrade, e.g. one made with
#   nix store add-file --store daemon <file>
# Prints ok/FAIL per check and exits non-zero if any check failed.
set -euo pipefail

want="${1:?usage: union-upgrade-check.sh <nix-version> <lower-path> [rw-path...]}"
lower="${2:?usage: union-upgrade-check.sh <nix-version> <lower-path> [rw-path...]}"
shift 2
rw=/nix/.rw-store/store
export PATH="/nix/var/nix/profiles/default/bin:$PATH"
pass=0; fail=0

check() { # <label> <command...>  — records ok/FAIL without aborting the run
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "ok    $label"; pass=$((pass+1)); else echo "FAIL  $label"; fail=$((fail+1)); fi
}
daemon_cmdline() {
  tr '\0' ' ' <"/proc/$(systemctl show -p MainPID --value nix-daemon.service)/cmdline"
}

check "client is Nix $want" test "$(nix --version | awk '{print $NF}')" = "$want"
check "daemon is Nix $want" test "$(nix store info --store daemon 2>&1 | sed -n 's/^Version: //p')" = "$want"
check "nix-daemon.service is active" systemctl is-active --quiet nix-daemon.service
check "/nix/store is fuse.mergerfs" test "$(findmnt -n -o FSTYPE /nix/store)" = fuse.mergerfs
check "daemon runs on the overlay store" grep -q 'local-overlay://' <(daemon_cmdline)
check "Lower Store path valid: $lower" nix path-info --store daemon "$lower"
check "Lower Store path not in the RW Branch" test ! -e "$rw/$(basename "$lower")"
for p in "$@"; do
  check "RW Branch path valid: $p" nix path-info --store daemon "$p"
  check "RW Branch path on disk: $p" test -e "$rw/$(basename "$p")"
done

echo; echo "passed=$pass failed=$fail"
test "$fail" = 0
