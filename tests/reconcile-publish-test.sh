#!/usr/bin/env bash
# Tests for the publish reconciler's git fetch retry (publish/reconcile-publish.sh,
# issue #26). Stub git and nix on PATH: git's fetch fails a set number of times
# (as a GitHub timeout would), nix stands in for `nix run .#publish`. Needs bash,
# coreutils and flock on PATH; runs as any user.
# Run from the checkout root: tests/reconcile-publish-test.sh [path/to/reconcile-publish.sh]
# (`nix flake check` runs it as checks.<system>.reconcile-publish).
set -euo pipefail

reconciler="$(realpath "${1:-publish/reconcile-publish.sh}")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

rev=49a0c66f269b0000000000000000000000000000

fails=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
check() { local name="$1"; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }

# Absolute shebangs: the nix build sandbox has no /usr/bin/env.
mkdir -p "$work/bin"
stub() { printf '#!%s\n' "$(command -v bash)" > "$work/bin/$1"; cat >> "$work/bin/$1"; chmod +x "$work/bin/$1"; }

# Stub git: `fetch` fails the first STUB_FETCH_FAILS times, then succeeds.
stub git <<'EOF'
printf '%s\n' "$*" >> "$STUB_LOG/git"
case "$1" in
  fetch)
    n=$(( $(cat "$STUB_LOG/fetches" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$STUB_LOG/fetches"
    if [ "$n" -le "${STUB_FETCH_FAILS:-0}" ]; then
      echo "fatal: unable to access 'https://github.com/grmhay/cvmfs-service/': Connection timed out" >&2
      exit 128
    fi ;;
  rev-parse) echo "$STUB_REV" ;;
  diff) exit 1 ;;
esac
exit 0
EOF

# Stub nix: records that the publish ran.
stub nix <<'EOF'
printf '%s\n' "$*" >> "$STUB_LOG/nix"
EOF

# One case = a fresh checkout dir, state dir and stub log. Sets $rc, $out and $case_dir.
run_case() {
  case_dir="$work/case-$1"; shift
  mkdir -p "$case_dir/checkout/publish" "$case_dir/state" "$case_dir/log"
  cp "$reconciler" "$case_dir/checkout/publish/reconcile-publish.sh"
  rc=0
  env PATH="$work/bin:$PATH" \
    PUBLISH_STATE_DIR="$case_dir/state" PUBLISH_LOCK="$case_dir/publish.lock" \
    PUBLISH_FETCH_PAUSE=0 \
    STUB_LOG="$case_dir/log" STUB_REV="$rev" "$@" \
    "$case_dir/checkout/publish/reconcile-publish.sh" > "$case_dir/out" 2>&1 || rc=$?
  out="$(cat "$case_dir/out")"
}
fetches() { cat "$case_dir/log/fetches" 2>/dev/null || echo 0; }
published() { [ "$(cat "$case_dir/state/published" 2>/dev/null)" = "$rev" ]; }
publish_ran() { grep -qx 'run .#publish' "$case_dir/log/nix" 2>/dev/null; }
publish_not_run() { [ ! -e "$case_dir/log/nix" ]; }

echo "# the fetch succeeds first time"
run_case ok
check "exits 0" [ "$rc" -eq 0 ]
check "fetches once" [ "$(fetches)" -eq 1 ]
check "runs the publish" publish_ran
check "records the published revision" published

echo "# the fetch fails twice, then succeeds"
run_case flaky STUB_FETCH_FAILS=2
check "exits 0" [ "$rc" -eq 0 ]
check "fetches three times" [ "$(fetches)" -eq 3 ]
check "logs each failed try" [ "$(grep -c 'git fetch .* failed' <<<"$out")" -eq 2 ]
check "runs the publish" publish_ran
check "records the published revision" published

echo "# the fetch keeps failing"
run_case down STUB_FETCH_FAILS=99
check "fails" [ "$rc" -ne 0 ]
check "stops after the default 3 tries" [ "$(fetches)" -eq 3 ]
check "says it gave up on the fetch" grep -q 'FAILED: git fetch .* failed 3 times' <<<"$out"
check "does not run the publish" publish_not_run
check "records nothing" [ ! -e "$case_dir/state/published" ]

echo "# the number of tries is set by PUBLISH_FETCH_TRIES"
run_case tries STUB_FETCH_FAILS=99 PUBLISH_FETCH_TRIES=5
check "fails" [ "$rc" -ne 0 ]
check "tries 5 times" [ "$(fetches)" -eq 5 ]

echo "# the pause between tries is set by PUBLISH_FETCH_PAUSE"
start=$SECONDS
run_case pause STUB_FETCH_FAILS=1 PUBLISH_FETCH_PAUSE=2
check "exits 0" [ "$rc" -eq 0 ]
check "waits between tries" [ $((SECONDS - start)) -ge 2 ]

if [ "$fails" -ne 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"
