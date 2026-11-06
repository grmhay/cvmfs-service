#!/usr/bin/env bash
# Fetch every valid store path whose files are missing, from the substituters
# nix.conf names (in cache Mode, the Repository's Binary Cache first).
#
# After a host leaves union Mode, the RW Branch is the plain /nix/store again,
# and its database still lists the Lower Store paths its own paths refer to.
# Their files stayed in the Lower Store. `nix-store --repair-path` fetches a
# valid path's files; `nix-store --verify --repair` does not (it drops such a
# path, or stops on one another path refers to; tests/fill-missing-paths-test.sh).
#
# Prints "filled <n>". Fails, naming each path, if any is still missing.
# FILL_STORE and FILL_ROOT point it at another store (the test's).
set -euo pipefail

root="${FILL_ROOT:-}"
store=()
if [ -n "${FILL_STORE:-}" ]; then store=(--store "$FILL_STORE"); fi

missing=()
while IFS= read -r path; do
  [ -e "$root$path" ] || missing+=("$path")
done < <(nix --extra-experimental-features nix-command "${store[@]}" path-info --all)

# One path at a time: one that cannot be fetched does not stop the rest.
still=()
for path in "${missing[@]}"; do
  nix-store "${store[@]}" --repair-path "$path" >&2 || true
  [ -e "$root$path" ] || still+=("$path")
done

if [ "${#still[@]}" -gt 0 ]; then
  printf 'fill-missing-paths: could not fetch %s\n' "${still[@]}" >&2
  exit 1
fi
printf 'filled %d\n' "${#missing[@]}"
