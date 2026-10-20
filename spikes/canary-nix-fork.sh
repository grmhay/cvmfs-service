#!/usr/bin/env bash
# Canary-only Nix fork (#14, docs/canary-nix-fork.md): switch this host's default
# profile to a fork build of Nix, or back. Run as root on a nix-canary host, with
# the fork's store path already in the local store (built here, or `nix copy`d in).
#
#   canary-nix-fork.sh install <store path of the fork's nix package>
#   canary-nix-fork.sh rollback        # back to the profile generation before install
#   canary-nix-fork.sh status
#
# install replaces the `nix` element of /nix/var/nix/profiles/default and keeps the
# others (nss-cacert), as `nix upgrade-nix` does, so the Union Store (RW Branch,
# mount, daemon drop-in) is left as it is. The systemd units link through that
# profile, so it reloads systemd and restarts nix-daemon onto the new Nix.
set -euo pipefail

profile=/nix/var/nix/profiles/default
suffix="${NIX_FORK_SUFFIX:-+chrootfix}"
nix_env="$profile/bin/nix-env"

restart_daemon() {
  # The socket refuses to restart while the service it triggered still runs, so
  # stop both, then start both, onto the units the profile now links to.
  systemctl daemon-reload
  systemctl stop nix-daemon.service nix-daemon.socket
  systemctl start nix-daemon.socket nix-daemon.service
}

status() {
  echo "profile:   $("$profile/bin/nix" --version)"
  echo "elements:  $("$nix_env" -p "$profile" -q | tr '\n' ' ')"
  # `nix store info` socket-activates the daemon if it is stopped
  echo "daemon:    $("$profile/bin/nix" store info --store daemon 2>&1 | sed -n 's/^Version: //p')"
}

case "${1:-}" in
  install)
    path="${2:?usage: $0 install <store path>}"
    [ -x "$path/bin/nix" ] || { echo "$path/bin/nix not found: is the fork in this store?" >&2; exit 1; }
    v="$("$path/bin/nix" --version)"
    case "$v" in *"$suffix") ;; *) echo "$path is not the fork ($v; expected a version ending in $suffix)" >&2; exit 1 ;; esac
    [ -e "$path/lib/systemd/system/nix-daemon.service" ] || { echo "$path has no systemd units: build the full nix package, not nix-cli" >&2; exit 1; }
    "$nix_env" -p "$profile" -i "$path"
    restart_daemon
    status
    case "$("$profile/bin/nix" store info --store daemon 2>&1)" in
      *"Version: ${v##* }"*) echo "ok    daemon runs the fork" ;;
      *) echo "FAIL  daemon does not report ${v##* }" >&2; exit 1 ;;
    esac
    ;;
  rollback)
    "$nix_env" -p "$profile" --rollback
    restart_daemon
    status
    ;;
  status) status ;;
  *) sed -n '5,8p' "$0" >&2; exit 2 ;;
esac
