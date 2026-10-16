#!/usr/bin/env bash
# Spike S3: create a Repository on the scratch bucket and publish hello into it
# the way publish/publish.sh does. Run as root on a throwaway Debian 13 VM, from
# a copy of the repo, after spikes/s3-scratch-bucket.sh has put the scratch keys
# in /root/s3-spike.keys. See docs/spikes/S3-mkfs-minio.md.
#
#   s3-publish.sh mkfs      # packages, Nix, s3.conf from the role template, mkfs
#   s3-publish.sh publish   # one transaction: hello (both systems) + dirtab, publish
#   s3-publish.sh check     # cvmfs_server check + anonymous reads of the bucket
#   s3-publish.sh rmfs      # remove the repository (the bucket is deleted by hand)
set -euo pipefail

repo=spike.hayweb.org
bucket=cvmfs-spike
s3_host=minio.hayweb.org:9000
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
role="$here/ansible/roles/cvmfs_publisher"
export PATH="/nix/var/nix/profiles/default/bin:$PATH"

fail=0
check() { # <label> <command...>
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "ok    $label"; else echo "FAIL  $label"; fail=1; fi
}
step() { echo; echo "== $*"; }
role_default() { # <key> — a plain scalar from the role's defaults
  sed -n "s/^$1: *\"\{0,1\}\([^\"#]*\)\"\{0,1\}.*$/\1/p" "$role/defaults/main.yml" | sed 's/ *$//'
}

do_mkfs() {
  step "packages (as the cvmfs_publisher role)"
  export DEBIAN_FRONTEND=noninteractive
  command -v curl >/dev/null || { apt-get -qq update; apt-get -qq install -y curl; }
  curl -fsSLo /tmp/cvmfs-release.deb "$(role_default cvmfs_release_deb)"
  dpkg -i /tmp/cvmfs-release.deb >/dev/null
  apt-get -qq update
  apt-get -qq install -y cvmfs cvmfs-server apache2 git sqlite3 >/dev/null
  echo "      $(cvmfs_server --version 2>/dev/null || dpkg-query -W cvmfs-server)"

  step "Nix (the nix_union_store role's pinned installer, upstream Nix)"
  if [ ! -e /nix/receipt.json ]; then
    v="$(sed -n 's/^nix_installer_version: *"\(.*\)"$/\1/p' "$here/ansible/roles/nix_union_store/defaults/main.yml")"
    curl -fsSL "https://install.determinate.systems/nix/tag/v$v" |
      NIX_INSTALLER_PREFER_UPSTREAM_NIX=true sh -s -- install linux --no-confirm --init systemd >/dev/null
  fi
  echo "      $(nix --version)"

  step "s3.conf from the role's template"
  test -s /root/s3-spike.keys || { echo "no /root/s3-spike.keys; run s3-scratch-bucket.sh create" >&2; exit 1; }
  { read -r ak; read -r sk; } </root/s3-spike.keys
  install -d -m 0755 /etc/cvmfs
  AK="$ak" SK="$sk" HOST="$s3_host" BUCKET="$bucket" awk '{
      gsub(/\{\{ cvmfs_s3_host \}\}/, ENVIRON["HOST"]);
      gsub(/\{\{ cvmfs_s3_bucket \}\}/, ENVIRON["BUCKET"]);
      gsub(/\{\{ publisher_secrets\.minio_access_key \}\}/, ENVIRON["AK"]);
      gsub(/\{\{ publisher_secrets\.minio_secret_key \}\}/, ENVIRON["SK"]);
      print }' "$role/templates/s3.conf.j2" >/etc/cvmfs/s3.conf
  chmod 0600 /etc/cvmfs/s3.conf
  ! grep -q '{{' /etc/cvmfs/s3.conf || { echo "unrendered template variable in s3.conf" >&2; exit 1; }
  grep -v -e ACCESS_KEY -e SECRET_KEY /etc/cvmfs/s3.conf | sed 's/^/      /'

  step "mkfs (as the role: -s s3.conf -w <bucket URL>)"
  if [ ! -d "/etc/cvmfs/repositories.d/$repo" ]; then
    cvmfs_server mkfs -s /etc/cvmfs/s3.conf -w "https://$s3_host/$bucket" -o root "$repo"
  fi
  # The role's two server.conf settings.
  conf="/etc/cvmfs/repositories.d/$repo/server.conf"
  sed -i '/^CVMFS_REPOSITORY_TTL=/d; /^CVMFS_AUTOCATALOGS=/d' "$conf"
  printf 'CVMFS_REPOSITORY_TTL=%s\nCVMFS_AUTOCATALOGS=false\n' "$(role_default cvmfs_repository_ttl)" >>"$conf"
  check "repository $repo exists" test -f "$conf"
  check "upstream is S3" grep -q '^CVMFS_UPSTREAM_STORAGE=S3' "$conf"
}

do_publish() {
  local root="/cvmfs/$repo" paths=() s
  step "build hello for both systems (aarch64 is substituted, not built)"
  for s in x86_64-linux aarch64-linux; do
    paths+=("$(nix build --no-link --print-out-paths "nixpkgs#legacyPackages.$s.hello")")
  done
  printf '      %s\n' "${paths[@]}"

  step "transaction (the steps of publish/publish.sh)"
  cvmfs_server transaction "$repo"
  trap 'echo "FAILED; aborting transaction"; cvmfs_server abort -f "$repo"' ERR
  install -m 0644 "$here/server/cvmfs/cvmfsdirtab" "$root/.cvmfsdirtab"
  nix copy --option auto-optimise-store false --no-check-sigs --to "local?root=$root" "${paths[@]}"
  sqlite3 "$root/nix/var/nix/db/db.sqlite" 'PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;' >/dev/null
  test ! -s "$root/nix/var/nix/db/db.sqlite-wal"
  nix copy --option auto-optimise-store false --no-check-sigs --to "file://$root/cache?compression=none" "${paths[@]}"
  for s in x86_64-linux aarch64-linux; do
    mkdir -p "$root/profiles/canary/spike"
    ln -sfn "${paths[0]}" "$root/profiles/canary/spike/$s.new"
    mv -T "$root/profiles/canary/spike/$s.new" "$root/profiles/canary/spike/$s"
    paths=("${paths[@]:1}")
  done
  cvmfs_server publish "$repo"
  trap - ERR
  cvmfs_server list
}

do_check() {
  local minio="https://$s3_host" code
  step "repository"
  check "cvmfs_server check $repo" cvmfs_server check "$repo"
  check "nested catalogs from the dirtab" bash -c "cvmfs_server list-catalogs $repo | grep -q '/nix/store/'"
  step "bucket, anonymously (no credentials)"
  check ".cvmfspublished fetchable" curl -fsS "$minio/$bucket/$repo/.cvmfspublished" -o /dev/null
  check ".cvmfswhitelist fetchable" curl -fsS "$minio/$bucket/$repo/.cvmfswhitelist" -o /dev/null
  code="$(curl -s "$minio/$bucket/" | sed -n 's:.*<Code>\([^<]*\)</Code>.*:\1:p')"
  check "listing refused (got: ${code:-none})" test "$code" = AccessDenied
}

case "${1:-}" in
  mkfs) do_mkfs ;;
  publish) do_publish ;;
  check) do_check ;;
  rmfs) cvmfs_server rmfs -f "$repo" ;;
  *) sed -n '9,12p' "$0" >&2; exit 2 ;;
esac
exit "$fail"
