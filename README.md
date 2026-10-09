# cvmfs-service

Fleet software distribution for the homelab: Nix Profiles are built once on the Publisher, published
to the CernVM-FS Repository `nix.hayweb.org` (MinIO origin, nginx cache), and appear on demand under
`/nix/store` on every host — Debian 13 and RHEL 10, x86_64 and aarch64 — without being copied locally.

```
cvmfs-service master ─▶ publisher VM ─▶ MinIO (minio.hayweb.org) ◀─ cache1 (nginx) ◀─ every host
                         builds x86_64 locally, aarch64 on pi5/pi6
host: /nix/store = mergerfs( /nix/.rw-store/store RW : /cvmfs/nix.hayweb.org/nix/store RO )
      PATH ⟵ /cvmfs/nix.hayweb.org/profiles/<channel>/<group>/<system>/bin
```

Vocabulary: `CONTEXT.md`. Decisions: `docs/adr/`. Design plan: `plans/0001-nix-over-cvmfs.md`.

## Layout

| Path | What |
|---|---|
| `flake.nix`, `profiles/` | One `buildEnv` Profile per host Group; `apps.{publish,promote,verify-origin}` |
| `publish/` | Publisher-side scripts: publish, promote, verify-origin, the 5-min publish reconciler |
| `ansible/roles/` | `cvmfs_client`, `nix_union_store` (union/cache/thin), `cvmfs_nginx_cache`, `cvmfs_publisher`, `nix_builder` |
| `ansible/playbooks/` | publisher, cache, builders, clients (inventory from NetBox) |
| `server/minio/` | Bucket policy + the by-hand runbook for the Origin |
| `secrets/` | SOPS/age ciphertext only |
| `docs/runbooks/`, `docs/spikes/` | Operations; the three go/no-go spikes |

## Day one

```sh
nix develop
nix flake check                        # builds every Profile for this machine
nix run .#publish -- --dry-run         # what would ship, without a transaction (needs aarch64 builders;
FLEET_SYSTEMS=x86_64-linux nix run .#publish -- --dry-run   #  …or restrict to this machine's system)
```

Phases and verification steps are in `plans/0001-nix-over-cvmfs.md`.
