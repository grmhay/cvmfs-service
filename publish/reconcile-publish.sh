#!/usr/bin/env bash
# Publish reconciler for the Publisher: converge the Repository's canary
# Channel to this repo's `master`. Same model as homelab-opscontrolplane's
# scripts/reconcile.sh — systemd oneshot + 5-min timer, non-root `publisher`
# user, gate on the last SUCCESSFULLY published revision (not the checkout),
# so a failed publish retries on the next tick without a new commit.
#
# A failed git fetch (a GitHub timeout, #26) is tried PUBLISH_FETCH_TRIES
# times in all (default 3), PUBLISH_FETCH_PAUSE seconds apart (default 30),
# before the run fails; the lock is held throughout.
#
# Usage: reconcile-publish.sh
set -euo pipefail

branch="${PUBLISH_BRANCH:-master}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
state_dir="${PUBLISH_STATE_DIR:-$HOME/.local/state/cvmfs-publish}"
published_file="$state_dir/published"
lock="${PUBLISH_LOCK:-/tmp/cvmfs-publish.lock}"
fetch_tries="${PUBLISH_FETCH_TRIES:-3}"
fetch_pause="${PUBLISH_FETCH_PAUSE:-30}"

log() { printf '%s reconcile-publish: %s\n' "$(date -Is)" "$*"; }

exec 9>"$lock"
if ! flock -n 9; then
  log "another publish or a resign holds $lock; exiting"
  exit 0
fi

cd "$repo_root"
try=1
until git fetch --quiet origin "$branch"; do
  if [ "$try" -ge "$fetch_tries" ]; then
    log "FAILED: git fetch origin $branch failed $try times; next run will retry"
    exit 1
  fi
  log "git fetch origin $branch failed (try $try of $fetch_tries); retrying in ${fetch_pause}s"
  sleep "$fetch_pause"
  try=$((try + 1))
done
remote_rev="$(git rev-parse "origin/$branch")"

mkdir -p "$state_dir"
last_ok=""
[ -f "$published_file" ] && last_ok="$(tr -d '[:space:]' < "$published_file")"

if [ "$last_ok" = "$remote_rev" ]; then
  log "already published ${remote_rev:0:12}; nothing to do"
  exit 0
fi

# Only inputs that change what ships trigger a publish; doc/role changes do not.
if [ -n "$last_ok" ] && git diff --quiet "$last_ok" "$remote_rev" -- flake.nix flake.lock profiles/; then
  log "${last_ok:0:12}..${remote_rev:0:12} touches no publish inputs; recording"
  printf '%s\n' "$remote_rev" > "$published_file"
  exit 0
fi

log "publishing ${last_ok:-<none>} -> ${remote_rev:0:12}"
git reset --hard --quiet "origin/$branch"

if nix run .#publish; then
  printf '%s\n' "$remote_rev" > "$published_file"
  log "published ${remote_rev:0:12}"
else
  log "FAILED: publish of ${remote_rev:0:12} did not complete; next run will retry"
  exit 1
fi
