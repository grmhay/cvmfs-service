#!/usr/bin/env bash
# Stand-in Lower Store: lets the nix_union_store role run in union Mode on a
# host with no Repository mounted (a throwaway vm-service VM), as spike S2 did.
# Run as root on the VM, from a copy of the repo (spikes/ and ansible/):
#
#   union-standin.sh [lower-root] [installable...]
#
# lower-root defaults to /srv/lower, installables to nixpkgs#hello. It installs
# Nix with the role's pinned Determinate installer if Nix is missing (the pin is
# read from the role's defaults beside this script; NIX_INSTALLER_VERSION
# overrides it), builds the
# installables into a plain Nix store at <lower-root>/nix (store/ + var/nix/db),
# checkpoints its db.sqlite out of WAL mode as the Publisher does (a read-only
# store opens it immutable and ignores a -wal file), and prints the store paths.
#
# Then, from ansible/ on the workstation (playbook: spikes/union-standin.yml):
#
#   ansible-playbook -i <host>, -u root \
#     ../spikes/union-standin.yml -e nix_union_check_path=<a path printed above>
#
# Expect /nix/store as fuse.mergerfs over /nix/.rw-store/store and the stand-in,
# the daemon on the overlay store, and a second run with changed=0.
#
# The playbook sets nix_lower_store to <lower-root>/nix (default /srv/lower/nix;
# pass -e nix_lower_store=... for another root). nix_union_check_path replaces
# the role's final check that the daemon serves the published Group Profile,
# which a stand-in does not have; -e nix_union_check_path= skips it.
set -euo pipefail

root="${1:-/srv/lower}"
[ $# -gt 0 ] && shift
[ $# -gt 0 ] || set -- nixpkgs#hello
defaults="$(dirname "$0")/../ansible/roles/nix_union_store/defaults/main.yml"
installer_version="${NIX_INSTALLER_VERSION:-$(sed -n 's/^nix_installer_version: *"\(.*\)"$/\1/p' "$defaults" 2>/dev/null)}"
[ -n "$installer_version" ] || { echo "no nix_installer_version in $defaults; set NIX_INSTALLER_VERSION" >&2; exit 2; }

if [ ! -e /nix/receipt.json ]; then
  command -v curl >/dev/null || { apt-get update -q && apt-get install -y -q curl; }
  # From v3.13.0 the installer defaults to Determinate Nix; the fleet runs upstream.
  curl -fsSL "https://install.determinate.systems/nix/tag/v$installer_version" |
    NIX_INSTALLER_PREFER_UPSTREAM_NIX=true sh -s -- install linux --no-confirm --init systemd
fi
export PATH="/nix/var/nix/profiles/default/bin:$PATH"

nix --extra-experimental-features 'nix-command flakes' \
  build --no-link --print-out-paths --store "$root" "$@"

python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("PRAGMA wal_checkpoint(TRUNCATE)"); c.execute("PRAGMA journal_mode=DELETE"); c.close()' \
  "$root/nix/var/nix/db/db.sqlite"
