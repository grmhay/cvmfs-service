#!/usr/bin/env bash
# Publish reconciler for the Publisher: converge the Repository's canary
# Channel to this repo's `master`. Same model as homelab-opscontrolplane's
# scripts/reconcile.sh — systemd oneshot + 5-min timer, non-root `publisher`
# user, gate on the last SUCCESSFULLY published revision (not the checkout),
# so a failed publish retries on the next tick without a new commit.
#
# Usage: reconcile-publish.sh
set -euo pipefail

branch="${PUBLISH_BRANCH:-master}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
state_dir="${PUBLISH_STATE_DIR:-$HOME/.local/state/cvmfs-publish}"
published_file="$state_dir/published"
lock="${PUBLISH_LOCK:-/tmp/cvmfs-publish.lock}"

log() { printf '%s reconcile-publish: %s\n' "$(date -Is)" "$*"; }

exec 9>"$lock"
if ! flock -n 9; then
  log "another run holds $lock; exiting"
  exit 0
fi

cd "$repo_root"
git fetch --quiet origin "$branch"
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
