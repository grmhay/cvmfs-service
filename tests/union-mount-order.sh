#!/usr/bin/env bash
# Boot ordering of the Union Store (#35): the units nix_union_store's own tasks
# write (tasks/daemon_units_boot_order.yml, run here into a scratch unit
# directory), next to the CVMFS client mount systemd-fstab-generator makes from
# cvmfs_client's fstab line and a Debian ifupdown network chain, booted to
# multi-user.target by `systemd --test`, which builds the same initial
# transaction systemd builds at boot and logs any ordering cycle in it.
#
# What went wrong (Publisher, 2026-10-30): systemd took the fuse.mergerfs union
# for a local filesystem and ordered it Before=local-fs.target. The network
# comes up after local-fs.target, and the union waits for the network and the
# client view, so the boot looped and systemd dropped a job to break it: the
# union one boot, network-online.target the next. And nix-daemon never started
# at boot: the installer's units are links into /nix/store, which is the empty
# mountpoint when systemd loads units.
#
# Two hosts: the Publisher (Lower Store in its client view, a cvmfs network
# mount, ADR 0004) and a Canary over the stand-in Lower Store (a local path).
#
# Needs ansible (to run the role's tasks) and the fleet's systemd: 257, as on
# Debian 13 and RHEL 10 (`systemd --test` runs unprivileged). Not a flake
# check: nixpkgs' systemd (262) no longer orders a fuse mount before
# local-fs.target, so the old unit's cycle does not show there. Run it in `nix develop` on a
# Debian 13 workstation. SYSTEMD= names another binary, UNITS= the directory of
# its stock units (default: the host's unit search path).
# Usage: tests/union-mount-order.sh   (from the checkout root, or set ROOT)
# DEBUG=1 prints systemd's warnings; KEEP=1 keeps the scratch units and dumps.
set -euo pipefail

root="${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
role="$root/ansible/roles/nix_union_store"
# The units of the Nix the host runs (here Nix 2.34.8's, which differ from
# 2.30.0's): what the default profile's lib/systemd/system holds.
installed="$root/tests/fixtures/nix-units"
systemd="${SYSTEMD:-/usr/lib/systemd/systemd}"
work="$(mktemp -d)"
if [ -n "${KEEP:-}" ]; then echo "work dir: $work" >&2; else trap 'rm -rf "$work"' EXIT; fi

fails=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
check() { local name="$1"; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }

# A play that runs one of the role's task files on this machine, as this user
# (no become). The handlers carry the role's names and do nothing: nothing here
# talks to systemd. The templates link is where the task files find the role's.
ln -s "$role/templates" "$work/templates"
cat > "$work/play.yml" <<'EOF'
- name: One of nix_union_store's task files, into a scratch unit directory
  hosts: localhost
  gather_facts: false
  handlers:
    - name: Reload systemd
      ansible.builtin.meta: noop
    - name: Restart nix-daemon
      ansible.builtin.meta: noop
  tasks:
    - name: The task file
      ansible.builtin.include_tasks: "{{ tasks_file }}"
EOF

# role_tasks <task file> <unit dir> [-e k=v ...]: the role's defaults, then overrides.
role_tasks() {
  local file="$1" dir="$2"
  shift 2
  ANSIBLE_LOCALHOST_WARNING=false ANSIBLE_INVENTORY_UNPARSED_WARNING=false \
    ansible-playbook -i localhost, -c local "$work/play.yml" \
    -e "@$role/defaults/main.yml" -e nix_system=x86_64-linux -e ansible_become=false \
    -e "tasks_file=$role/tasks/$file" -e "nix_systemd_unit_dir=$dir" \
    -e "nix_installed_units_dir=$installed" "$@" \
    > "$work/ansible.log" 2>&1 \
    || { cat "$work/ansible.log"; exit 2; }
}

# enable <dir> <unit>: what `systemctl enable` links, from the unit's [Install].
enable() {
  local dir="$1" unit="$2" target
  while read -r target; do
    mkdir -p "$dir/$target.wants"
    ln -sfn "../$unit" "$dir/$target.wants/$unit"
  done < <(sed -n 's/^WantedBy=//p' "$dir/$unit")
}

# host <name> <client view or ""> [-e ...]: the unit set one host boots with.
host() {
  local name="$1" view="$2" dir="$work/$1"
  shift 2
  mkdir -p "$dir"

  # The installer links its units into /etc/systemd/system from the default
  # profile, which lives in /nix/store: on a union host that is the empty
  # mountpoint when systemd loads units at boot, so the links dangle.
  ln -s "$work/empty-nix-store/nix-daemon.service" "$dir/nix-daemon.service"
  ln -s "$work/empty-nix-store/nix-daemon.socket" "$dir/nix-daemon.socket"
  mkdir -p "$dir/sockets.target.wants"
  ln -s "$work/empty-nix-store/nix-daemon.socket" "$dir/sockets.target.wants/nix-daemon.socket"

  # The role's units, from its own tasks: its daemon units over the installer's
  # links, the union, and the daemon's drop-in. Then what union.yml's
  # `enabled: true` links.
  role_tasks daemon_units_boot_order.yml "$dir" "$@"
  enable "$dir" nix-store.mount
  enable "$dir" nix-daemon.socket

  # What systemd-fstab-generator writes for `<repo> <view> cvmfs defaults,_netdev`.
  if [ -n "$view" ]; then
    local unit
    unit="$(systemd-escape --path --suffix=mount "$view")"
    printf '[Unit]\nBefore=remote-fs.target\n[Mount]\nWhat=nix.hayweb.org\nWhere=%s\nType=cvmfs\nOptions=defaults,_netdev\n' \
      "$view" > "$dir/$unit"
    mkdir -p "$dir/remote-fs.target.requires"
    ln -s "../$unit" "$dir/remote-fs.target.requires/$unit"
  fi

  # Debian's ifupdown: after local-fs.target, before network-online.target.
  cat > "$dir/networking.service" <<'EOF'
[Unit]
DefaultDependencies=no
Wants=network.target
After=local-fs.target network-pre.target
Before=network.target network-online.target
[Service]
Type=oneshot
ExecStart=/bin/true
EOF
  mkdir -p "$dir/network-online.target.wants"
  ln -s ../networking.service "$dir/network-online.target.wants/networking.service"
}

# boot <name>: the initial transaction to multi-user.target, with this host's
# units first on the search path and no generators (the host's own fstab and
# the like stay out). Writes <dir>/dump (units, their jobs and dependencies)
# and <dir>/log (warnings: each ordering cycle and the job dropped to break it).
boot() {
  local dir="$work/$1"
  mkdir -p "$work/no-generators"
  SYSTEMD_UNIT_PATH="$dir:${UNITS:-}" SYSTEMD_GENERATOR_PATH="$work/no-generators" \
    SYSTEMD_LOG_LEVEL=warning SYSTEMD_LOG_TARGET=console \
    "$systemd" --test --system --no-pager --unit=multi-user.target > "$dir/dump" 2> "$dir/log"
  if [ -n "${DEBUG:-}" ]; then cat "$dir/log" >&2; fi
}

# unit <name> <unit>: that unit's block of the dump.
unit() {
  awk -v u="$2" '/^\t→ Unit /{on = ($0 == "\t→ Unit " u ":")} on' "$work/$1/dump"
}

no_cycle() {
  ! grep -qi 'ordering cycle' "$work/$1/log" \
    || { grep -i 'deleted to break' "$work/$1/log" | sed 's/^/       /'; false; }
}
# Not grep -q: under pipefail, awk killed by SIGPIPE would fail the match.
# starts <name> <unit>: the boot transaction has a job for it.
starts() { unit "$1" "$2" | grep $'^\t\t-> Job ' > /dev/null; }
# has <name> <unit> <"Dep: other">: the unit carries that dependency.
has() { unit "$1" "$2" | grep -F $'\t\t'"$3 (" > /dev/null; }
lacks() { ! has "$@"; }
# from_installed <name> <unit>: the role's unit is the installed Nix's, as is
# (the role's changes are drop-ins), under the role's header comment.
from_installed() { diff <(grep -v '^#' "$work/$1/$2") "$installed/$2" > /dev/null; }

# Every host in union Mode boots the same way; only the Lower Store differs.
boots_cleanly() {
  local name="$1"
  boot "$name"
  check "$name: the boot transaction has no ordering cycle" no_cycle "$name"
  check "$name: the union is not ordered before local-fs.target" \
    lacks "$name" nix-store.mount "Before: local-fs.target"
  check "$name: the union mounts after network-online.target" \
    has "$name" nix-store.mount "After: network-online.target"
  check "$name: remote-fs.target waits for the union" \
    has "$name" remote-fs.target "After: nix-store.mount"
  check "$name: the boot mounts the union" starts "$name" nix-store.mount
  check "$name: the boot starts nix-daemon.socket" starts "$name" nix-daemon.socket
  check "$name: nix-daemon.socket listens after the union" \
    has "$name" nix-daemon.socket "After: nix-store.mount"
  check "$name: nix-daemon.service runs after the union" \
    has "$name" nix-daemon.service "After: nix-store.mount"
  check "$name: basic.target does not wait for the union (via sockets.target)" \
    lacks "$name" sockets.target "After: nix-daemon.socket"
  check "$name: nix-daemon.service is the installed Nix's" \
    from_installed "$name" nix-daemon.service
  check "$name: nix-daemon.socket is the installed Nix's" \
    from_installed "$name" nix-daemon.socket
}

# The Publisher: the Lower Store is its client view (ADR 0004), a cvmfs mount.
host publisher /cvmfs-client/nix.hayweb.org -e cvmfs_client_mountpoint=/cvmfs-client/nix.hayweb.org
boots_cleanly publisher
check "publisher: the union mounts after the client view" \
  has publisher nix-store.mount 'After: cvmfs\x2dclient-nix.hayweb.org.mount'

# A Canary over the stand-in Lower Store (spikes/union-standin.sh): a local path.
host canary "" -e nix_lower_store=/srv/lower/nix
boots_cleanly canary
check "canary: the union is the RW Branch over the stand-in Lower Store" \
  grep -qx 'What=/nix/.rw-store/store=RW:/srv/lower/nix/store=RO' "$work/canary/nix-store.mount"

[ "$fails" -eq 0 ]
