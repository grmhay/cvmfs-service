#!/usr/bin/env bash
# Tests for publish/drop-path-catalogs.sh (#44): in a fixture Lower Store, the
# catalog markers the old dirtab (/nix/store/*) left go, and nothing else does.
# Needs bash, coreutils and find on PATH; runs as any user.
# Run from the checkout root: tests/drop-path-catalogs-test.sh [path/to/drop-path-catalogs.sh]
# (`nix flake check` runs it as checks.<system>.drop-path-catalogs).
set -euo pipefail

script="$(realpath "${1:-publish/drop-path-catalogs.sh}")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fails=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
check() { local name="$1"; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
exits_nonzero() { ! "$@" >/dev/null 2>&1; }

# A Lower Store as the old layout published it: a marker in every store path
# and in .links, plus the new one at /nix.
nix="$work/nix"
store="$nix/store"
mkdir -p "$store/aaaa-hello/bin" "$store/bbbb-lib/share/doc" "$store/.links" "$nix/var/nix/db"
for d in "$store/aaaa-hello" "$store/bbbb-lib" "$store/.links"; do : > "$d/.cvmfscatalog"; done
echo hello > "$store/aaaa-hello/bin/hello"
# A file of that name deeper inside a path is the path's own content.
: > "$store/bbbb-lib/share/doc/.cvmfscatalog"
# So is one at a path's top with content (a package that ships the file).
mkdir -p "$store/cccc-cvmfs-tools"
echo shipped > "$store/cccc-cvmfs-tools/.cvmfscatalog"
: > "$nix/.cvmfscatalog"
: > "$nix/var/nix/db/db.sqlite"

"$script" "$store"

check "drops the marker in each store path" \
  test ! -e "$store/aaaa-hello/.cvmfscatalog" -a ! -e "$store/bbbb-lib/.cvmfscatalog"
check "drops the marker in .links" test ! -e "$store/.links/.cvmfscatalog"
check "keeps the store paths' contents" test -s "$store/aaaa-hello/bin/hello"
check "keeps a file of that name deeper inside a path" test -e "$store/bbbb-lib/share/doc/.cvmfscatalog"
check "keeps a path's own file of that name with content" test -s "$store/cccc-cvmfs-tools/.cvmfscatalog"
check "keeps the Lower Store's own marker at /nix" test -e "$nix/.cvmfscatalog"
check "keeps the database" test -e "$nix/var/nix/db/db.sqlite"

"$script" "$store"
check "a second run succeeds and keeps what the first kept" \
  test -s "$store/aaaa-hello/bin/hello" -a -e "$store/bbbb-lib/share/doc/.cvmfscatalog" -a -e "$nix/.cvmfscatalog"

check "refuses a directory that is not a store" exits_nonzero "$script" "$work/missing"

if [ "$fails" -gt 0 ]; then
  printf '%d check(s) failed\n' "$fails"
  exit 1
fi
printf 'all checks passed\n'
