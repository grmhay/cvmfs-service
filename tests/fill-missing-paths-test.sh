#!/usr/bin/env bash
# Leaving union Mode for cache Mode (#29 criterion 6): once the RW Branch is
# the plain /nix/store again, its database still lists the Lower Store paths
# that its own paths refer to, and their files are not on the local disk.
# fill-missing-paths.sh must fetch every one of them from the substituters.
#
# Why not `nix-store --verify --repair`, which the role ran first (task 248,
# 2026-11-05)? It fetches no path that nothing refers to: it drops it from the
# database. Then it tried to drop a path that a path it had just fetched refers
# to; SQLite refused (FOREIGN KEY constraint failed), and the run stopped with
# paths still missing.
#
# Runs against a throwaway local store and a file:// Binary Cache, so it needs
# nix on PATH and no daemon. It covers Nix only: the overlay store and the
# role's tasks are checked on a Canary host's round trip.
# Usage: tests/fill-missing-paths-test.sh <fill-missing-paths.sh>
# (`nix flake check` runs it as checks.<system>.fill-missing-paths).
set -euo pipefail

fill="$(realpath "${1:?usage: fill-missing-paths-test.sh <fill-missing-paths.sh>}")"
work="$(mktemp -d)"
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT

fails=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
check() { local name="$1"; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
exits_nonzero() { ! "$@" >/dev/null 2>&1; }

root="$work/root"
store="local?root=$root"
cache="file://$work/cache"
nixs() { nix --extra-experimental-features nix-command --store "$store" "$@"; }
# A path whose contents name $2, so Nix records it as referring to $2.
refers_to() {
  nixs eval --impure --raw --expr \
    "builtins.toFile \"$1\" \"uses \${builtins.storePath \"$2\"}\""
}
on_disk() { test -e "$root$1"; }
# Removes a path's files and leaves its database row: what the move back to a
# plain /nix/store does to every Lower Store path.
lose() { chmod -R u+w "$root$1" "$root/nix/store"; rm -rf "${root:?}$1"; }

mkdir -p "$work/src/leaf"
echo leaf > "$work/src/leaf/file"
leaf="$(nixs store add --name leaf "$work/src/leaf")"
mid="$(refers_to mid "$leaf")"
top="$(refers_to top "$mid")"
mkdir -p "$work/src/lone"
echo lone > "$work/src/lone/file"
lone="$(nixs store add --name lone "$work/src/lone")"
nixs copy --to "$cache" "$top" "$lone"

export NIX_CONFIG="substituters = $cache
require-sigs = false"

# The deb1 case: a chain with its middle and bottom gone, and a path nothing
# refers to.
lose "$mid"
lose "$leaf"
lose "$lone"
out="$(FILL_STORE="$store" FILL_ROOT="$root" "$fill")"
check "fills a path that a path on disk refers to" on_disk "$mid"
check "fills the path that one refers to" on_disk "$leaf"
check "fills a path that nothing refers to" on_disk "$lone"
check "says how many it filled" test "$out" = "filled 3"
check "the store verifies afterwards" nixs store verify --all --no-trust

# A rerun (the role runs it on every cache Mode run, not only after the move).
out="$(FILL_STORE="$store" FILL_ROOT="$root" "$fill")"
check "a rerun with nothing missing fills nothing" test "$out" = "filled 0"

# A missing path the substituters do not have: fail, and name it.
rm -rf "$work/cache"
nixs copy --to "$cache" "$lone"
lose "$top"
check "fails when a missing path cannot be fetched" \
  exits_nonzero env FILL_STORE="$store" FILL_ROOT="$root" "$fill"
err="$(FILL_STORE="$store" FILL_ROOT="$root" "$fill" 2>&1 || true)"
check "names the path it could not fetch" grep -qF "$top" <<<"$err"

if [ "$fails" -gt 0 ]; then
  printf '%d check(s) failed\n' "$fails"
  exit 1
fi
printf 'all checks passed\n'
