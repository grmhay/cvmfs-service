#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2012  # $out is for the builder; store names are plain
# Sandbox acceptance checks on a Union Store host (spike S2; canary acceptance test, #6).
# Usage (as root; /nix/store must be the mergerfs union):
#   s2-nix-chroot-fix.sh <nix-cli out path>   swap in nix-daemon from that build, on the spike's
#                                             stand-in Lower Store (/srv/lower), for the checks
#   s2-nix-chroot-fix.sh --installed          check the host's own nix-daemon as the role configured
#                                             it; the daemon and its configuration are left untouched
# Exits non-zero if any check fails. With a Nix lacking the chroot-parent fix the union checks fail
# and the plain-store check passes.
set -uo pipefail
case ${1:?usage: s2-nix-chroot-fix.sh <nix-cli out path> | --installed} in
  --installed)
    installed=1 nixpkg=/nix/var/nix/profiles/default
    # the role's drop-in passes the overlay store URL to the daemon only (clients use store = daemon)
    url=$(systemctl show -p ExecStart --value nix-daemon.service | sed -n 's/.* --option store \([^ ]*\) .*/\1/p')
    [ -n "$url" ] || { echo "nix-daemon.service has no --option store: not a Union Store host"; exit 2; } ;;
  *)
    installed='' nixpkg=$1
    url='local-overlay://?lower-store=local%3Froot%3D%2Fsrv%2Flower%26read-only%3Dtrue&upper-layer=/nix/.rw-store/store&check-mount=false' ;;
esac
rw_branch=${url#*upper-layer=}; rw_branch=${rw_branch%%&*}
pass=0 fail=0
ok()  { echo "ok    $*"; pass=$((pass+1)); }
bad() { echo "FAIL  $*"; fail=$((fail+1)); }
expr_of() { echo "derivation { name = \"$1-$$-$RANDOM\"; system = builtins.currentSystem; builder = \"/bin/sh\"; args = [ \"-c\" \"$2\" ]; }"; }
nb() { "$nixpkg/bin/nix" build --no-link --option sandbox true --impure "$@"; }

[ "$(findmnt -no FSTYPE /nix/store)" = fuse.mergerfs ] || { echo "/nix/store is not the union"; exit 2; }

wait_daemon() {  # <client store args...>
  for _ in $(seq 50); do "$nixpkg/bin/nix" store info "$@" >/dev/null 2>&1 && return; sleep 0.2; done
  echo "daemon did not start"; journalctl -u nixd-test -n 20 --no-pager; exit 2
}
start_daemon() {  # replace the host's daemon; extra daemon options as args
  systemctl stop nix-daemon.socket nix-daemon nixd-test 2>/dev/null
  systemctl reset-failed nixd-test 2>/dev/null
  systemd-run -q --unit=nixd-test -p KillMode=mixed "$nixpkg/bin/nix-daemon" --daemon --option store "$url" "$@"
  wait_daemon
}
side_sock=/run/nixd-test.sock
side_daemon() {  # a second daemon on its own socket, beside the host's; extra daemon options as args
  systemctl stop nixd-test 2>/dev/null; systemctl reset-failed nixd-test 2>/dev/null; rm -f "$side_sock"
  systemd-run -q --unit=nixd-test -p KillMode=mixed -E NIX_DAEMON_SOCKET_PATH="$side_sock" \
    "$nixpkg/bin/nix-daemon" --daemon --option store "$url" "$@"
  wait_daemon --store "unix://$side_sock"
}
if [ -n "$installed" ]; then
  # builds may socket-activate the host's daemon; stop it again only if it was not running
  was_active=$(systemctl is-active nix-daemon.service)
  trap 'systemctl stop nixd-test 2>/dev/null; rm -f "$side_sock"; [ "$was_active" = active ] || systemctl stop nix-daemon.service' EXIT
else
  trap 'systemctl stop nixd-test 2>/dev/null; systemctl start nix-daemon.socket nix-daemon' EXIT
fi

echo "== daemon $("$nixpkg/bin/nix-daemon" --version) from $nixpkg${installed:+ (installed)}"
[ -n "$installed" ] || start_daemon

# 1. minimal sandboxed build
if nb --expr "$(expr_of t1 'echo hi > \$out')"; then ok "minimal sandboxed build"; else bad "minimal sandboxed build"; fi

# 2. chroot parent mode/owner, and another build user cannot traverse it
# (the sandbox's busybox has no sleep applet, so the builder spins instead)
nb --expr "$(expr_of t2 'i=0; while [ \$i -lt 4000000 ]; do i=\$((i+1)); done; echo hi > \$out')" >/tmp/t2.log 2>&1 & bpid=$!
for _ in $(seq 600); do c=$(ls -d "$rw_branch"/*-t2-*.chroot 2>/dev/null | head -1); [ -n "$c" ] && break; sleep 0.05; done
if [ -n "$c" ]; then
  st=$(stat -c '%a %U:%G' "$c"); owner=${st#* }; owner=${owner%%:*}
  echo "      chroot parent: $st"
  other=nixbld1; [ "$owner" = nixbld1 ] && other=nixbld2
  if [ "${st%% *}" = 100 ] && [ "${owner#nixbld}" != "$owner" ]; then ok "parent is 0100 owned by the build user ($owner)"; else bad "parent mode/owner is $st"; fi
  if runuser -u "$other" -- ls "$c/root" >/dev/null 2>&1; then bad "$other can list the chroot root"; else ok "$other cannot traverse the chroot (backing dir)"; fi
  m=/nix/store/$(basename "$c")
  if runuser -u "$other" -- ls "$m/root" >/dev/null 2>&1; then bad "$other can list the chroot root via the union"; else ok "$other cannot traverse the chroot (union)"; fi
  if runuser -u "$owner" -- ls "$c" >/dev/null 2>&1; then bad "the build user can list the parent"; else ok "the build user cannot list the parent (traverse only)"; fi
else bad "no chroot dir observed"; fi
if wait $bpid; then ok "long-running sandboxed build"; else bad "long-running sandboxed build"; tail -3 /tmp/t2.log; fi

# 3. a real package rebuilt in the sandbox (inputs on both branches)
hello=$("$nixpkg/bin/nix" build --no-link --print-out-paths nixpkgs#hello 2>/dev/null | head -1)
if [ -n "$hello" ] && "$nixpkg/bin/nix" build --no-link --option sandbox true --rebuild nixpkgs#hello >/tmp/t3.log 2>&1; then ok "nixpkgs#hello rebuilt in the sandbox"; else bad "nixpkgs#hello rebuild"; tail -5 /tmp/t3.log; fi

# 4. auto-allocate-uids
aau=(--option extra-experimental-features auto-allocate-uids --option auto-allocate-uids true)
if [ -n "$installed" ]; then side_daemon "${aau[@]}"; t4store=(--store "unix://$side_sock"); else start_daemon "${aau[@]}"; t4store=(); fi
if nb "${t4store[@]}" --expr "$(expr_of t4 'echo hi > \$out')" 2>/tmp/t4.log; then ok "sandboxed build with auto-allocate-uids"; else bad "auto-allocate-uids"; tail -3 /tmp/t4.log; fi
if [ -n "$installed" ]; then systemctl stop nixd-test; else start_daemon; fi

# 5. plain kernel-filesystem store (regression check), via a chroot store on ext4/xfs
rm -rf /srv/plain
if "$nixpkg/bin/nix" build --no-link --store /srv/plain --option sandbox true --option build-users-group nixbld --impure --expr "$(expr_of t5 'echo hi > \$out')" >/tmp/t5.log 2>&1; then ok "sandboxed build on a plain store"; else bad "plain store"; tail -3 /tmp/t5.log; fi
rm -rf /srv/plain

# 6. a chroot store whose root is on its own mergerfs mount (no local-overlay store involved);
#    the shape of a NixOS VM test for upstream
mkdir -p /srv/fbranch /srv/funion
mergerfs -o allow_other,category.create=ff /srv/fbranch /srv/funion
if "$nixpkg/bin/nix" build --no-link --store /srv/funion/root --option sandbox true --option build-users-group nixbld --impure --expr "$(expr_of t6 'echo hi > \$out')" >/tmp/t6.log 2>&1; then ok "sandboxed build in a chroot store on mergerfs"; else bad "chroot store on mergerfs"; tail -3 /tmp/t6.log; fi
umount /srv/funion; rm -rf /srv/fbranch /srv/funion

echo "== $pass passed, $fail failed"
[ "$fail" = 0 ]
