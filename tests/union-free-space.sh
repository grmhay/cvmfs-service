#!/usr/bin/env bash
# The Union Store's free-space floor (#81), against a real mergerfs: one with
# the role's mount options, over a RW Branch on a 3 GiB tmpfs and a read-only
# stand-in Lower Store.
#
# What went wrong (workstation, 2026-11-20): mergerfs's minfreespace defaults
# to 4 GiB. With category.create=ff, a branch with less free space than that
# takes no creates; the only branch left is the read-only Lower Store, so every
# write to /nix/store failed with "Read-only file system" while / still had
# 3.9 GiB free. Nix's min-free (2G) sits below that floor, so its GC never ran.
#
# Runs in a user and mount namespace of its own (unprivileged user namespaces,
# FUSE, and mergerfs on PATH: Debian 13's package). Not a flake check: the
# build sandbox has no /dev/fuse. Run it in `nix develop` (for ansible).
# Usage: tests/union-free-space.sh   (from the checkout root, or set ROOT)
set -euo pipefail

if [ -z "${UNION_FREE_SPACE_NS:-}" ]; then
  UNION_FREE_SPACE_NS=1 exec unshare --user --map-root-user --mount "$0" "$@"
fi

root="${ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
role="$root/ansible/roles/nix_union_store"
work="$(mktemp -d)"
trap 'umount "$work/store" 2>/dev/null || true; umount "$work/rw" 2>/dev/null || true; rm -rf "$work"' EXIT

fails=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
check() { local name="$1"; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }

# The RW Branch: 3 GiB free, under mergerfs's own 4 GiB default floor and over
# Nix's 2G min-free. The Lower Store: a plain directory, mounted read-only.
mkdir -p "$work/rw" "$work/lower" "$work/store"
mount -t tmpfs -o size=3G tmpfs "$work/rw"
echo lower > "$work/lower/in-lower"

# role_var <expr>: a Jinja expression over the role's defaults.
role_var() {
  ANSIBLE_LOCALHOST_WARNING=false ANSIBLE_INVENTORY_UNPARSED_WARNING=false \
    ansible localhost -i localhost, -c local -m ansible.builtin.copy \
    -a "content={{ $1 }} dest=$work/var" -e "@$role/defaults/main.yml" > "$work/ansible.log" 2>&1 \
    || { cat "$work/ansible.log"; exit 2; }
  cat "$work/var"
}

# mount_union <options>: the union over the scratch branches. allow_other is
# dropped: in a user namespace fuse refuses it without user_allow_other.
mount_union() {
  local opts
  opts="$(printf '%s' "$1" | tr , '\n' | grep -vx allow_other | paste -sd,)"
  mergerfs -o "$opts" "$work/rw=RW:$work/lower=RO" "$work/store" 2> "$work/mergerfs.log" \
    || { cat "$work/mergerfs.log"; exit 2; }
}

# writes <what>: a create in the union lands in the RW Branch.
writes() {
  { echo x > "$work/store/$1"; } 2> "$work/write.log" \
    || { sed 's/^/       /' "$work/write.log"; return 1; }
  test -f "$work/rw/$1"
}

mount_union "$(role_var mergerfs_options)"
check "the role's options: a RW Branch with 3 GiB free takes writes" writes new-path
check "the role's options: the Lower Store still reads through" grep -qx lower "$work/store/in-lower"
umount "$work/store"
rm -f "$work/rw/new-path"

refuses() { ! writes "$1" > /dev/null; }

# A play that runs one of the role's task files here, as this user (no become).
cat > "$work/play.yml" <<'EOF'
- name: One of nix_union_store's task files, on a scratch union
  hosts: localhost
  gather_facts: false
  tasks:
    - name: The task file
      ansible.builtin.include_tasks: "{{ tasks_file }}"
EOF

# free_space_task [-e k=v ...]: tasks/union_free_space.yml on the scratch union,
# over the role's defaults. Writes $work/run.log; fails as the play fails.
free_space_task() {
  ANSIBLE_LOCALHOST_WARNING=false ANSIBLE_INVENTORY_UNPARSED_WARNING=false \
    ansible-playbook -i localhost, -c local "$work/play.yml" \
    -e "@$role/defaults/main.yml" -e ansible_become=false \
    -e "tasks_file=$role/tasks/union_free_space.yml" \
    -e "nix_union_control_file=$work/store/.mergerfs" "$@" > "$work/run.log" 2>&1
}
# changed: the last run changed something.
changed() { grep -Eq 'changed=[1-9]' "$work/run.log"; }
unchanged() { grep -q 'changed=0' "$work/run.log"; }
ran() { free_space_task "$@" || { sed 's/^/       /' "$work/run.log"; return 1; }; }

# A union mounted before the floor was set (every host before #81) keeps
# mergerfs's default until it is remounted: a new unit leaves it as it is.
mount_union "$(role_var mergerfs_options | sed 's/,minfreespace=[^,]*//')"
check "a union on mergerfs's default floor refuses writes" refuses old-floor
check "union_free_space.yml lowers the floor of a mounted union" ran
check "union_free_space.yml reports the change" changed
check "the mounted union now takes writes" writes after-task
check "union_free_space.yml again: nothing to change" ran
check "union_free_space.yml again: reports no change" unchanged

# A floor at or above Nix's min-free: mergerfs would stop writes before Nix's
# GC runs. The run stops before it touches the union.
refused() {
  ! free_space_task "$@" && grep -q 'must be under nix_min_free' "$work/run.log"
}
check "a floor equal to min-free is refused" refused -e nix_union_minfreespace=2G -e nix_min_free=2G
check "a floor above min-free is refused" refused -e nix_union_minfreespace=4G -e nix_min_free=2G
floor() { python3 -c 'import os, sys; print(os.getxattr(sys.argv[1], "user.mergerfs.minfreespace").decode())' "$work/store/.mergerfs"; }
check "a refused floor leaves the mounted union's as it was" test "$(floor)" = 1073741824
umount "$work/store"

[ "$fails" -eq 0 ]
