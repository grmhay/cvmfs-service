#!/usr/bin/env bash
# Tests for the unattended resign wrapper (ansible/roles/cvmfs_publisher/files/cvmfs-resign.sh,
# issue #19). Real sops and age, a throwaway age identity, and a stub cvmfs_server that records
# what it saw. Needs bash, coreutils, sops and age-keygen on PATH; runs as any user.
# Run from the checkout root: tests/cvmfs-resign-test.sh [path/to/cvmfs-resign.sh]
# (`nix flake check` runs it as checks.<system>.resign-wrapper).
set -euo pipefail

wrapper="$(realpath "${1:-ansible/roles/cvmfs_publisher/files/cvmfs-resign.sh}")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fails=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }
check() { local name="$1"; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }

# A known-good key, escrowed the way publish/masterkey-escrow.sh does it.
key_text=$'-----BEGIN RSA PRIVATE KEY-----\nMIIEtest\n-----END RSA PRIVATE KEY-----'
age-keygen -o "$work/age.txt" 2>/dev/null
recipient="$(age-keygen -y "$work/age.txt")"
printf 'creation_rules:\n  - age: %s\n' "$recipient" > "$work/.sops.yaml"
printf '%s\n' "$key_text" | { printf 'masterkey: |\n'; sed 's/^/  /'; } > "$work/plain.yaml"
sops --config "$work/.sops.yaml" encrypt "$work/plain.yaml" > "$work/masterkey.enc.yaml"
rm -f "$work/plain.yaml"

# Stub cvmfs_server: records its arguments, whether the key was readable and
# what it held, then exits with STUB_RC.
mkdir -p "$work/bin"
# Absolute shebang: the nix build sandbox has no /usr/bin/env.
printf '#!%s\n' "$(command -v bash)" > "$work/bin/cvmfs_server"
cat >> "$work/bin/cvmfs_server" <<'EOF'
printf '%s\n' "$*" >> "$STUB_LOG/calls"
if [ -f "$RESIGN_MASTERKEY" ]; then cat "$RESIGN_MASTERKEY" > "$STUB_LOG/seen-key"; fi
if [ -L "$RESIGN_MASTERKEY" ]; then readlink "$RESIGN_MASTERKEY" > "$STUB_LOG/seen-link"; fi
exit "${STUB_RC:-0}"
EOF
chmod +x "$work/bin/cvmfs_server"

# The publish reconciler's lock, which the role creates (owned by publisher).
: > "$work/publish.lock"

# Hold the publish lock in the background for $1 seconds, as a running publish would.
hold_lock() {
  flock "$work/publish.lock" sleep "$1" &
  holder=$!
  sleep 0.3
}

# One case = a fresh keys dir, runtime dir and stub log. Sets $rc and $err.
run_case() {
  case_dir="$work/case-$1"; shift
  mkdir -p "$case_dir/keys" "$case_dir/run" "$case_dir/log"
  chmod 0700 "$case_dir/run"
  rc=0
  env PATH="$work/bin:$PATH" \
    CVMFS_REPOSITORY=nix.example.org \
    RESIGN_SECRET="${SECRET:-$work/masterkey.enc.yaml}" \
    RESIGN_MASTERKEY="$case_dir/keys/nix.example.org.masterkey" \
    RUNTIME_DIRECTORY="$case_dir/run" \
    SOPS_AGE_KEY_FILE="${AGE_KEY:-$work/age.txt}" \
    RESIGN_LOCK="${LOCK:-$work/publish.lock}" RESIGN_LOCK_WAIT="${LOCK_WAIT:-5}" \
    STUB_LOG="$case_dir/log" STUB_RC="${STUB_RC:-0}" \
    "$wrapper" "$@" 2> "$case_dir/stderr" || rc=$?
  err="$(cat "$case_dir/stderr")"
}
no_key_left() { [ ! -e "$case_dir/keys/nix.example.org.masterkey" ] && [ ! -L "$case_dir/keys/nix.example.org.masterkey" ]; }
run_dir_empty() { [ -z "$(ls -A "$case_dir/run")" ]; }
not_called() { [ ! -e "$case_dir/log/calls" ]; }

echo "# before escrow: no masterkey.enc.yaml"
SECRET="$work/absent.enc.yaml" run_case no-secret
check "fails" [ "$rc" -ne 0 ]
check "names masterkey-escrow" grep -q masterkey-escrow <<<"$err"
check "does not call cvmfs_server" not_called
check "leaves no master key" no_key_left

echo "# resign succeeds"
run_case ok
check "exits 0" [ "$rc" -eq 0 ]
check "runs cvmfs_server resign <repo>" grep -qx 'resign nix.example.org' "$case_dir/log/calls"
check "cvmfs_server read the escrowed key" diff -q <(printf '%s\n' "$key_text") "$case_dir/log/seen-key"
check "the key it read lived in the runtime dir (tmpfs)" grep -q "^$case_dir/run/" "$case_dir/log/seen-link"
check "leaves no master key" no_key_left
check "leaves the runtime dir empty" run_dir_empty

echo "# cvmfs_server resign fails"
STUB_RC=3 run_case resign-fails
check "fails" [ "$rc" -ne 0 ]
check "says the resign failed" grep -q 'cvmfs_server resign nix.example.org failed' <<<"$err"
check "leaves no master key" no_key_left
check "leaves the runtime dir empty" run_dir_empty

echo "# the age key cannot decrypt the secret"
age-keygen -o "$work/other-age.txt" 2>/dev/null
AGE_KEY="$work/other-age.txt" run_case wrong-age-key
check "fails" [ "$rc" -ne 0 ]
check "says it could not decrypt" grep -q 'could not decrypt' <<<"$err"
check "does not call cvmfs_server" not_called
check "leaves no master key" no_key_left
check "leaves the runtime dir empty" run_dir_empty

echo "# a master key file is already there (escrow unfinished, or a resign by hand)"
pre_existing() {
  mkdir -p "$work/case-$1/keys"
  printf 'hand-placed\n' > "$work/case-$1/keys/nix.example.org.masterkey"
}
pre_existing hand-placed
run_case hand-placed
check "fails" [ "$rc" -ne 0 ]
check "says a key is already there" grep -q 'already' <<<"$err"
check "does not call cvmfs_server" not_called
check "leaves that file alone" grep -qx hand-placed "$case_dir/keys/nix.example.org.masterkey"
check "leaves the runtime dir empty" run_dir_empty

echo "# a killed run left its symlink behind"
mkdir -p "$work/case-stale/keys"
ln -s "$work/case-stale/run/masterkey" "$work/case-stale/keys/nix.example.org.masterkey"
run_case stale
check "resigns anyway" [ "$rc" -eq 0 ]
check "leaves no master key" no_key_left

echo "# cleanup (ExecStopPost) after a kill"
mkdir -p "$work/case-killed/keys" "$work/case-killed/run"
printf '%s\n' "$key_text" > "$work/case-killed/run/masterkey"
ln -s "$work/case-killed/run/masterkey" "$work/case-killed/keys/nix.example.org.masterkey"
run_case killed cleanup
check "exits 0" [ "$rc" -eq 0 ]
check "removes the symlink" no_key_left
check "shreds the tmpfs copy" run_dir_empty
check "does not call cvmfs_server" not_called

echo "# cleanup leaves a hand-placed key alone"
pre_existing cleanup-hand
run_case cleanup-hand cleanup
check "exits 0" [ "$rc" -eq 0 ]
check "leaves that file alone" grep -qx hand-placed "$case_dir/keys/nix.example.org.masterkey"

echo "# a publish holds the lock for longer than the resign waits"
hold_lock 5
LOCK_WAIT=1 run_case lock-held
wait "$holder"
check "fails" [ "$rc" -ne 0 ]
check "says a publish holds the lock" grep -q 'publish lock' <<<"$err"
check "does not call cvmfs_server" not_called
check "leaves no master key" no_key_left
check "leaves the runtime dir empty" run_dir_empty

echo "# a publish finishes while the resign waits"
hold_lock 1
LOCK_WAIT=10 run_case lock-wait
wait "$holder"
check "exits 0" [ "$rc" -eq 0 ]
check "runs cvmfs_server resign <repo>" grep -qx 'resign nix.example.org' "$case_dir/log/calls"
check "leaves no master key" no_key_left

echo "# the publish lock file is missing"
LOCK="$work/absent.lock" run_case no-lock
check "fails" [ "$rc" -ne 0 ]
check "names the lock file" grep -q absent.lock <<<"$err"
check "does not call cvmfs_server" not_called
check "does not create it" [ ! -e "$work/absent.lock" ]

if [ "$fails" -ne 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"
