#!/usr/bin/env bash
# Publish every Group Profile for every fleet system into the Repository's
# `canary` Channel. Runs on the Publisher as the repository owner, by hand or
# from publish/reconcile-publish.sh.
#
# One CVMFS transaction does three things (ADR 0001):
#   1. `nix copy` the closures into the Lower Store
#      (/cvmfs/<repo>/nix/store + /nix/var/nix/db) that union-mode hosts
#      mount read-only under /nix/store;
#   2. `nix copy` the same closures into the fallback Binary Cache
#      (/cvmfs/<repo>/cache, uncompressed nars — CVMFS compresses/dedups);
#   3. flip /cvmfs/<repo>/profiles/canary/<group>/<system> to the new Profile.
# Nothing is ever deleted from the Repository (retention: never, year one).
#
# Env (set by the flake app wrapper): CVMFS_REPOSITORY, FLEET_GROUPS, FLEET_SYSTEMS.
# Usage: publish.sh [--channel canary] [--flake <ref>] [--dry-run]
set -euo pipefail

repo="${CVMFS_REPOSITORY:?}"
groups="${FLEET_GROUPS:?}"
systems="${FLEET_SYSTEMS:?}"
channel="canary"
flake="${PUBLISH_FLAKE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
dry_run=0

while [ $# -gt 0 ]; do
  case "$1" in
    --channel) channel="$2"; shift 2 ;;
    --flake) flake="$2"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

log() { printf '%s publish[%s]: %s\n' "$(date -Is)" "$repo" "$*"; }

root="/cvmfs/$repo"
commit="$(git -C "$flake" rev-parse HEAD 2>/dev/null || echo unknown)"

# ---- 1. build (remote builders do aarch64; failure here never opens a transaction)
declare -A outs=()
for system in $systems; do
  for group in $groups; do
    attr="$flake#packages.$system.profile-$group"
    log "building $attr"
    out="$(nix build --no-link --print-out-paths "$attr")"
    outs["$group/$system"]="$out"
  done
done

if [ "$dry_run" = 1 ]; then
  for k in "${!outs[@]}"; do printf '%s -> %s\n' "$k" "${outs[$k]}"; done
  exit 0
fi

# ---- 2. transaction
cvmfs_server transaction "$repo"
trap 'log "FAILED; aborting transaction"; cvmfs_server abort -f "$repo"' ERR

# Hardlink optimisation is pointless here (CVMFS dedups by content) and
# cross-directory hardlinks do not survive publishing.
nix_opts=(--option auto-optimise-store false --no-check-sigs)

paths=("${outs[@]}")
log "copying ${#paths[@]} profile closures into the lower store"
nix copy "${nix_opts[@]}" --to "local?root=$root" "${paths[@]}"

# Clients open the Lower Store read-only, which SQLite does as immutable and
# so ignores a -wal file: fold the WAL into db.sqlite and leave the DB out of
# WAL mode, or clients see an empty or stale store (spike S2).
log "checkpointing the lower store DB"
db="$root/nix/var/nix/db/db.sqlite"
sqlite3 "$db" 'PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;' >/dev/null
test ! -s "$db-wal"

log "copying the same closures into the fallback binary cache"
nix copy "${nix_opts[@]}" --to "file://$root/cache?compression=none" "${paths[@]}"

for k in "${!outs[@]}"; do
  group="${k%/*}"; system="${k#*/}"
  dir="$root/profiles/$channel/$group"
  mkdir -p "$dir"
  # Absolute target: on a union-mode host /nix/store IS the merged store, so
  # the link resolves there; cache-mode hosts read the target as a path to copy.
  ln -sfn "${outs[$k]}" "$dir/$system.new"
  mv -T "$dir/$system.new" "$dir/$system"
done

printf '%s\n' "$commit" > "$root/.published-commit"

log "publishing"
cvmfs_server publish "$repo"
trap - ERR
log "published commit ${commit:0:12} to channel $channel"
