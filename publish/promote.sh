#!/usr/bin/env bash
# Promote: re-point the `stable` Channel at whatever `canary` currently points
# to, for one Group or all. No rebuild — the store paths are already in the
# Repository. With --commit, record the new pointers in profiles/pointers.json
# and commit, so git history is the audit trail of what stable has been.
#
# Usage: promote.sh (<group>|all) [--commit]
set -euo pipefail

repo="${CVMFS_REPOSITORY:?}"
groups="${FLEET_GROUPS:?}"
systems="${FLEET_SYSTEMS:?}"
flake="${PUBLISH_FLAKE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
target="${1:?usage: promote.sh (<group>|all) [--commit]}"; shift
do_commit=0
[ "${1:-}" = "--commit" ] && do_commit=1

log() { printf '%s promote[%s]: %s\n' "$(date -Is)" "$repo" "$*"; }

root="/cvmfs/$repo"
[ "$target" = all ] || groups="$target"

cvmfs_server transaction "$repo"
trap 'log "FAILED; aborting transaction"; cvmfs_server abort -f "$repo"' ERR

pointers="$flake/profiles/pointers.json"
for group in $groups; do
  for system in $systems; do
    src="$root/profiles/canary/$group/$system"
    [ -L "$src" ] || { log "no canary pointer for $group/$system; skipping"; continue; }
    out="$(readlink "$src")"
    dir="$root/profiles/stable/$group"
    mkdir -p "$dir"
    ln -sfn "$out" "$dir/$system.new"
    mv -T "$dir/$system.new" "$dir/$system"
    log "stable/$group/$system -> $out"
    if [ "$do_commit" = 1 ]; then
      tmp="$(mktemp)"
      jq --arg k "$group/$system" --arg v "$out" '.stable[$k] = $v' "$pointers" > "$tmp"
      mv "$tmp" "$pointers"
    fi
  done
done

cvmfs_server publish "$repo"
trap - ERR

if [ "$do_commit" = 1 ]; then
  git -C "$flake" add profiles/pointers.json
  git -C "$flake" commit -q -m "promote: stable <- canary ($target)"
  log "pointers committed; push when ready"
fi
