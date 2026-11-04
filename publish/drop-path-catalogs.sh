#!/usr/bin/env bash
# Drop the catalog markers that the old dirtab (/nix/store/*) put in each store
# path and in .links (#44). A marker inside a path changes its contents, so Nix
# sees it as modified, and in .links it broke every host's GC (#42). Removing
# one merges that nested catalog into its parent; no content goes. Only
# markers directly in an entry of the store directory: a file of that name
# deeper inside a path is the path's own.
# Runs inside the publish transaction (publish/publish.sh); idempotent.
# Usage: drop-path-catalogs.sh <store-dir>
set -euo pipefail

store="${1:?usage: drop-path-catalogs.sh <store-dir>}"
[ -d "$store" ] || { echo "drop-path-catalogs: no store at $store" >&2; exit 1; }

find "$store" -mindepth 2 -maxdepth 2 -name .cvmfscatalog -type f -delete
