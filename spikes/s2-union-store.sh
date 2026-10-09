#!/usr/bin/env bash
# Spike S2: mergerfs union store + Nix local-overlay-store. Run as root on a
# throwaway VM with Nix (Determinate) and mergerfs installed.
#
#   s2-union-store.sh <ro-branch>
#
# <ro-branch> is either a real CVMFS lower store (/cvmfs/<repo>/nix/store) or a
# plain directory holding a Nix store tree. With a plain directory the script
# simulates a repository revision flip by swapping the directory out.
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
lower="local%3Froot%3D$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=""))' "$lower_root")%26read-only%3Dtrue"
cat > /etc/nix/nix.conf <<EOF
experimental-features = nix-command flakes local-overlay-store
auto-optimise-store = false
store = local-overlay://?root=/&lower-store=$lower&upper-layer=$rw&check-mount=false
EOF
systemctl start nix-daemon.socket
check "nix store info" nix store info --store auto

step "4. local build lands in RW; GC leaves RO alone"
before="$(find "$ro" -maxdepth 1 | wc -l)"
out="$(nix build --no-link --print-out-paths nixpkgs#hello || true)"
check "nix build nixpkgs#hello" test -n "$out"
check "built path is in the RW branch" test -e "$rw/$(basename "${out:-none}")"
nix-collect-garbage -d >/dev/null || true
check "RO branch untouched by GC" test "$(find "$ro" -maxdepth 1 | wc -l)" = "$before"

step "5. revision flip under load"
if [ -n "$bin" ] && [ ! -e /cvmfs ]; then
  "$via" >/dev/null; sleep 300 & keep=$!   # stand-in for a long-running process from the RO branch
  new="$ro.new"; cp -a "$ro" "$new"; mkdir "$new/zzz-published-after-mount"; mv "$ro" "$ro.old"; mv "$new" "$ro"
  check "new lower path visible without remount" test -d /nix/store/zzz-published-after-mount
  check "running process survived the flip" kill -0 "$keep"
  kill "$keep" 2>/dev/null || true
  if dmesg | tail -20 | grep -qi 'fuse\|estale'; then echo "FAIL  FUSE/ESTALE noise in dmesg"; fail=$((fail+1)); else echo "ok    dmesg clean"; pass=$((pass+1)); fi
else
  echo "skip  real CVMFS branch: perform a publish from the Publisher and re-run the checks by hand"
fi

step "6. exec latency"
if command -v hyperfine >/dev/null && [ -n "$bin" ]; then
  hyperfine -N --warmup 5 "$bin" "$via" || true
else
  echo "skip  hyperfine not installed (nix shell nixpkgs#hyperfine)"
fi

echo; echo "passed=$pass failed=$fail"
test "$fail" = 0
