# 0006 — One nested catalog for the Lower Store, rooted at /nix

Status: accepted (2026-11-03). Amends ADR 0001's nested-catalog consequence (#44).

## Context

The dirtab had `/nix/store/*`, which gives one nested catalog per store path. CVMFS marks a nested
catalog with a `.cvmfscatalog` file in its root directory, and clients see that file. So every
published store path held one extra file that its NAR hash didn't cover:

- `nix store verify --no-trust` failed on every published path on every union host.
- A copy out of a union host (`nix copy`, `nix-store --serve`) would serialise the marker, and the
  receiver would reject the path on its hash.
- The same glob matched `.links`, whose marker made every host's GC fail (#42).

The live root catalog on 2026-11-03 showed:
- 480 store paths, each its own catalog;
- about 70k entries in the whole Repository (8.1k directories, 55k files, 7k symlinks);
- a root catalog of 138 KB compressed for about 1k entries.

## Decision

- The dirtab has `/nix` in place of `/nix/store/*`, so the whole Lower Store (`store/` and
  `var/nix/db`) is one nested catalog. Its marker is `/nix/.cvmfscatalog`, beside `store/`, where Nix
  never looks. `/cache/*` and `/profiles/*/*` stay as they are.
- Not `/nix/store`: Nix's GC deletes every entry in the store directory that is not a valid path. On
  a union host that entry would be on the read-only branch, and GC would fail the way #42 did.
  `tests/store-catalog-marker-test.sh` (a flake check) pins both behaviours.
- `publish/drop-path-catalogs.sh` removes the old per-path markers in every transaction. That merges
  their catalogs into the new one. Only the markers go, never content. It's idempotent.
- Nothing has to make store-path directories writable for CVMFS any more. The `chmod u+w` that
  publish.sh ran on new paths for their markers is gone. Paths published earlier stay `u+w`.

## Consequences

- Published paths verify, and a union host can be the source of a copy.
- **Clients fetch more per revision.** The Lower Store catalog is about 65k entries today, an
  estimated 8–10 MB compressed, and every union host fetches it again on each new revision (from the
  Cache, so the Origin serves it once). The old layout fetched only the root catalog and the catalogs
  of the paths a host touched.
- **The catalog only grows.** Retention is never (year one), so it gains every published path. CVMFS
  advises keeping catalogs under a few hundred thousand entries. Watch its size and revisit before it
  gets there. Splitting it again needs a directory the marker can sit in that is neither inside a
  store path nor the store directory, which Nix's layout doesn't have. The way out then is fewer
  revisions, or a separate Repository.
