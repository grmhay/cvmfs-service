#!/usr/bin/env bash
# Spike S2: mergerfs union store + Nix local-overlay-store. Run as root on a
# throwaway VM with Nix (Determinate) and mergerfs installed.
#
#   s2-union-store.sh <ro-branch>
#
# <ro-branch> is either a real CVMFS lower store (/cvmfs/<repo>/nix/store) or a
# plain directory holding a Nix store tree. With a plain directory the script
# simulates a repository revision flip by swapping the directory out.
#
# Plain-directory stand-in (the lower store needs its Nix DB beside it):
#   nix build --no-link --store /srv/lower nixpkgs#hello
#   s2-union-store.sh /srv/lower/nix/store
#
# S2_BUILD_PKG (default nixpkgs#cowsay) and S2_LATE_PKG (default nixpkgs#ripgrep)
# must not already be in the lower store.
set -euo pipefail

ro="${1:?usage: s2-union-store.sh <ro-branch-dir>}"
rw=/nix/.rw-store/store
opts="category.create=ff,inodecalc=path-hash,cache.files=auto-full,cache.negative_entry=0,cache.entry=1,cache.attr=1,allow_other,fsname=nixstore"
pass=0; fail=0

check() { # <label> <command...>  — records ok/FAIL without aborting the run
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "ok    $label"; pass=$((pass+1)); else echo "FAIL  $label"; fail=$((fail+1)); fi
}
step() { echo; echo "== $*"; }

step "1. mount"
systemctl stop nix-daemon.socket nix-daemon.service || true
if mountpoint -q /nix/store; then umount /nix/store; fi   # re-run
if [ ! -d "$rw" ]; then mkdir -p "$(dirname "$rw")"; mv /nix/store "$rw"; mkdir /nix/store; fi
mergerfs -o "$opts" "$rw=RW:$ro=RO" /nix/store
check "fuse.mergerfs on /nix/store" test "$(findmnt -n -o FSTYPE /nix/store)" = fuse.mergerfs

step "2. exec from the RO branch (mmap)"
bin="$(find "$ro" -maxdepth 3 -path '*/bin/hello' | head -1 || true)"
via=""
if [ -n "$bin" ]; then
  via="/nix/store/${bin#"$ro"/}"
  check "ran $via" "$via"
else
  echo "skip  no hello binary on RO branch; copy nixpkgs#hello there first"
fi

step "3. nix daemon with local-overlay-store over the union"
lower_root="$(dirname "$(dirname "$ro")")"
# What the Publisher does before every publish: a read-only lower store is
# opened immutable, which ignores a -wal file.
checkpoint() {
  python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("PRAGMA wal_checkpoint(TRUNCATE)"); c.execute("PRAGMA journal_mode=DELETE"); c.close()' \
    "$lower_root/nix/var/nix/db/db.sqlite"
}
checkpoint
lower="local%3Froot%3D$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$lower_root")%26read-only%3Dtrue"
url="local-overlay://?lower-store=$lower&upper-layer=$rw&check-mount=false"
# As the nix_union_store role: clients use the daemon; only the daemon opens the overlay.
cat > /etc/nix/nix.conf <<CONF
experimental-features = nix-command flakes local-overlay-store read-only-local-store
build-users-group = nixbld
auto-optimise-store = false
store = daemon
CONF
mkdir -p /etc/systemd/system/nix-daemon.service.d
cat > /etc/systemd/system/nix-daemon.service.d/overlay-store.conf <<CONF
[Service]
ExecStart=
ExecStart=@/nix/var/nix/profiles/default/bin/nix-daemon nix-daemon --daemon --option store ${url//%/%%}
CONF
systemctl daemon-reload
systemctl start nix-daemon.socket
check "nix store info (via daemon)" nix store info
check "a lower path is valid through the overlay" nix path-info "${via:-/nix/store/none}"

step "4. local build lands in RW; GC leaves RO alone"
before="$(find "$ro" -maxdepth 1 | wc -l)"
pkg="${S2_BUILD_PKG:-nixpkgs#cowsay}"
out="$(nix build --no-link --print-out-paths "$pkg" || true)"
check "nix build $pkg" test -n "$out"
check "built path is in the RW branch" test -e "$rw/$(basename "${out:-none}")"
# A substituted package proves nothing about building: build a minimal
# derivation for real, in and out of the sandbox.
# sandbox=true is a known failure: Nix creates <drv>.chroot 0700 under the store
# and mergerfs resolves paths as the build user (docs/spikes/S2-union-store.md).
# It passes once upstream makes that directory traversable; until then the role
# sets sandbox = false (or build-users-group =) on union hosts.
for sb in true false; do
  expr="derivation { name = \"s2-local-build-$sb-$$\"; system = builtins.currentSystem; builder = \"/bin/sh\"; args = [ \"-c\" \"echo hi > \$out\" ]; }"
  if [ "$sb" = true ]; then
    if nix build --no-link --option sandbox true --impure --expr "$expr" >/dev/null 2>&1; then echo "ok    local build, sandbox=true (upstream fixed the chroot mode?)"; pass=$((pass+1)); else echo "known local build, sandbox=true fails (Nix chroot 0700 on mergerfs)"; fi
  else
    check "local build, sandbox=false" nix build --no-link --option sandbox false --impure --expr "$expr"
  fi
done
nix-collect-garbage -d >/dev/null || true
check "RO branch untouched by GC" test "$(find "$ro" -maxdepth 1 | wc -l)" = "$before"

step "5. revision flip under load"
if [ -n "$bin" ] && [ "${ro#/cvmfs/}" = "$ro" ]; then
  "$via" >/dev/null; sleep 300 & keep=$!   # stand-in for a long-running process from the RO branch
  marker="zzz-published-after-mount-$$"   # not a store path: removed again below
  new="$ro.new"; rm -rf "$ro.old"; cp -a "$ro" "$new"; mkdir "$new/$marker"; mv "$ro" "$ro.old"; mv "$new" "$ro"
  check "new lower path visible without remount" test -d "/nix/store/$marker"
  rmdir "$ro/$marker"
  check "running process survived the flip" kill -0 "$keep"
  kill "$keep" 2>/dev/null || true
  if dmesg | tail -20 | grep -qi 'fuse\|estale'; then echo "FAIL  FUSE/ESTALE noise in dmesg"; fail=$((fail+1)); else echo "ok    dmesg clean"; pass=$((pass+1)); fi
else
  echo "skip  real CVMFS branch: perform a publish from the Publisher and re-run the checks by hand"
fi

step "7. a new daemon connection sees a path added to the lower DB after the daemon started"
late="$(nix build --no-link --print-out-paths --store "local?root=$lower_root" "${S2_LATE_PKG:-nixpkgs#ripgrep}" | head -1 || true)"
check "path added to the lower store" test -n "$late"
checkpoint
check "daemon reports it valid" nix path-info --store daemon "${late:-/nix/store/none}"
check "visible through the union" test -e "${late:-/nix/store/none}"

step "6. exec latency"
if command -v hyperfine >/dev/null && [ -n "$bin" ]; then
  hyperfine -N --warmup 5 "$bin" "$via" || true
else
  echo "skip  hyperfine not installed (nix shell nixpkgs#hyperfine)"
fi

echo; echo "passed=$pass failed=$fail"
test "$fail" = 0
