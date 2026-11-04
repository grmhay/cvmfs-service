#!/usr/bin/env bash
# Where CVMFS's catalog marker may sit in a Nix store (#44). The Repository has
# one nested catalog for the Lower Store, rooted at /nix, so the Lower Store
# carries a /nix/.cvmfscatalog beside store/ and var/. Nix must leave that
# alone: verify passes and GC neither fails on it nor removes it.
#
# The two places it may not sit, and why:
#   - inside a store path (the old one-catalog-per-path layout): it changes the
#     path's contents, and verify fails;
#   - in /nix/store itself: GC deletes every entry there that is not a valid
#     path, which on a union host is the read-only branch (as .links was, #42).
#
# Runs against a throwaway local store, so it needs nix on PATH and no daemon.
# It covers Nix only: the mergerfs union and the overlay store are checked on
# the hosts (#44's "Done when").
# Run from anywhere: tests/store-catalog-marker-test.sh
# (`nix flake check` runs it as checks.<system>.store-catalog-marker).
set -euo pipefail

work="$(mktemp -d)"
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT

fails=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
check() { local name="$1"; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
exits_nonzero() { ! "$@" >/dev/null 2>&1; }

store="local?root=$work/root"
nixs() { nix --extra-experimental-features nix-command --store "$store" "$@"; }

mkdir -p "$work/src/kept/bin" "$work/src/dead"
echo kept > "$work/src/kept/bin/hello"
echo dead > "$work/src/dead/file"
kept="$(nixs store add --name kept "$work/src/kept")"
dead="$(nixs store add --name dead "$work/src/dead")"
# A GC root keeps $kept; $dead is garbage.
mkdir -p "$work/root/nix/var/nix/gcroots"
ln -s "$kept" "$work/root/nix/var/nix/gcroots/kept"

marker="$work/root/nix/.cvmfscatalog"
: > "$marker"

check "verify passes with the marker at /nix" nixs store verify --all --no-trust
check "GC succeeds with the marker at /nix" nixs store gc
check "GC leaves the marker at /nix in place" test -e "$marker"
check "GC still collects garbage" test ! -e "$work/root$dead"
check "GC keeps a rooted path" test -e "$work/root$kept"

# A marker in /nix/store itself is garbage to GC.
store_dir="$work/root/nix/store"
chmod u+w "$store_dir"
: > "$store_dir/.cvmfscatalog"
nixs store gc >/dev/null 2>&1
check "GC removes a marker in /nix/store, so the catalog cannot be rooted there" \
  test ! -e "$store_dir/.cvmfscatalog"

# The old layout: a marker inside a store path. verify must catch it, or the
# check above would pass for any layout.
chmod u+w "$work/root$kept"
: > "$work/root$kept/.cvmfscatalog"
check "verify fails with a marker inside a store path" exits_nonzero nixs store verify --no-trust "$kept"

if [ "$fails" -gt 0 ]; then
  printf '%d check(s) failed\n' "$fails"
  exit 1
fi
printf 'all checks passed\n'
