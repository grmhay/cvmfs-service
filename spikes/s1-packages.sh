#!/usr/bin/env bash
# Spike S1: install the packages the roles assume, the way the roles install
# them, and report versions. Run as root on a throwaway host (Debian 13 or
# RHEL 10, either arch). See docs/spikes/S1-packages.md.
#
#   s1-packages.sh
set -euo pipefail

# Keep in step with the role defaults.
cvmfs_release_deb=https://ecsft.cern.ch/dist/cvmfs/cvmfs-release/cvmfs-release-latest_all.deb
cvmfs_release_rpm=https://ecsft.cern.ch/dist/cvmfs/cvmfs-release/cvmfs-release-latest.noarch.rpm
mergerfs_version=2.40.2
nix_installer_url=https://install.determinate.systems/nix/tag/v3.8.0

pass=0; fail=0
check() { # <label> <command...>  — records ok/FAIL without aborting the run
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "ok    $label"; pass=$((pass+1)); else echo "FAIL  $label"; fail=$((fail+1)); fi
}
step() { echo; echo "== $*"; }

# shellcheck source=/dev/null
. /etc/os-release
arch="$(uname -m)"
step "host: $PRETTY_NAME $arch, kernel $(uname -r)"

# The Debian template ships without curl (the nix_union_store role installs it).
command -v curl >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get -qq install -y curl >/dev/null

step "1. cvmfs + cvmfs-server"
case "$ID" in
  debian)
    curl -fsSLo /tmp/cvmfs-release.deb "$cvmfs_release_deb"
    dpkg -i /tmp/cvmfs-release.deb >/dev/null
    apt-get -qq update
    check "apt install cvmfs cvmfs-server" env DEBIAN_FRONTEND=noninteractive apt-get -qq install -y cvmfs cvmfs-server
    ;;
  rhel)
    check "dnf repos enabled (BaseOS/AppStream for dependencies)" test -n "$(dnf -q repolist --enabled 2>/dev/null)"
    check "dnf install cvmfs-release" dnf -q -y install "$cvmfs_release_rpm"
    check "dnf install cvmfs cvmfs-server" dnf -q -y install cvmfs cvmfs-server
    ;;
esac
echo "      cvmfs: $(cvmfs2 --version 2>/dev/null || echo missing)"
check "cvmfs_server present" command -v cvmfs_server

step "2. mergerfs"
case "$ID" in
  debian) check "apt install mergerfs" env DEBIAN_FRONTEND=noninteractive apt-get -qq install -y mergerfs ;;
  rhel) check "dnf install mergerfs $mergerfs_version el10 RPM" dnf -q -y install \
          "https://github.com/trapexit/mergerfs/releases/download/$mergerfs_version/mergerfs-$mergerfs_version-1.el10.$arch.rpm" ;;
esac
echo "      mergerfs: $(mergerfs --version 2>/dev/null | head -1 || echo missing)"

step "3. Nix (Determinate installer, pinned)"
if ! command -v nix >/dev/null && [ ! -x /nix/var/nix/profiles/default/bin/nix ]; then
  curl -fsSL "$nix_installer_url" | sh -s -- install linux --no-confirm --init systemd >/dev/null
fi
nix=/nix/var/nix/profiles/default/bin/nix
echo "      nix: $("$nix" --version)"
check "nix --version >= 2.22" sh -c "\"$nix\" --version | grep -Eo '[0-9]+\.[0-9]+' | tail -1 | awk -F. '{ exit !(\$1 > 2 || (\$1 == 2 && \$2 >= 22)) }'"
check "local-overlay-store is a known store type" sh -c "\"$nix\" help-stores 2>/dev/null | grep -qi 'local overlay'"

echo; echo "passed=$pass failed=$fail"
test "$fail" = 0
