# Fleet software is distributed as Nix closures through a CernVM-FS repository

Hosts today get software as digest-pinned Docker images (via `homelab-opscontrolplane`) or binaries
curl'd from GitHub releases. Every service flake already builds `x86_64-linux` and `aarch64-linux`, so
Nix is the build system; what was missing is distribution that does not copy every closure onto every
host.

Nix closures are built once on the Publisher and published into one CernVM-FS repository,
`nix.hayweb.org`, whose upstream storage is the existing MinIO (Origin) and whose clients read through
an nginx reverse cache. Each host mounts the repository and assembles `/nix/store` as a union of a
local writable branch and the repository's read-only Lower Store (ADR 0002), so published paths are
visible immediately and fetched on demand, bounded by the CVMFS client's LRU quota. Hosts put one
composite Profile per host Group on PATH, chosen by Channel (`canary`/`stable`). The same transaction
also publishes a Binary Cache (narinfo/nar, uncompressed) so a host can fall back to an ordinary local
`/nix` fed from CVMFS. Service packages enter the fleet as pinned flake inputs of this repo; Renovate
bumps them; the Publisher's reconciler publishes `master` every five minutes. Nothing is deleted from
the repository in its first year.

## Considered Options

- **Nix binary cache only (Attic/Harmonia/nix-serve, or the cache in CVMFS) with ordinary local
  `/nix`** — standard, proven, no union filesystem; but every host copies every closure it uses
  (roughly 2× disk) and needs a per-host install step and profile state to reconcile. Kept as the
  fallback Mode, not the primary.
- **CVMFS only, no local Nix daemon ("thin")** — simplest client, but no local builds or `nix shell`
  on hosts. Kept as a Mode switch for hosts that cannot run mergerfs; no host uses it today.
- **Docker images for everything** — the current model; fine for services on skyline, wrong for host
  tooling and standalone binaries, and no answer for the Pis and cloud hosts.
- **Mounting the repository at `/nix` directly** (store dir inside `/cvmfs`) — requires a Nix built
  with a non-standard store dir and loses `cache.nixos.org`. Rejected.

## Consequences

- One repository holds both architectures; store-path hashes keep them apart. No per-arch repos.
- Publish is atomic and global; rollout control lives in the `canary`/`stable` symlinks per Group.
- The Publisher is the single writer and holds the signing key; the master key lives in SOPS and is
  only placed on the Publisher to `resign`.
- The MinIO bucket is anonymous-read on LAN + VPN: CVMFS verifies every object against the repository
  signature, so transport confidentiality is not relied on.
- CVMFS's nested catalogs (`/nix/store/*`) mean a client downloads metadata only for the paths it
  touches; the root catalog stays small as the store grows.
- Hardlink optimisation is off everywhere (`auto-optimise-store = false`): CVMFS dedups by content
  and cross-directory hardlinks do not survive publishing.
- The host model depends on mergerfs behaving under a changing read-only branch (ADR 0002); spike S2
  is the go/no-go and the cache Mode is the exit.
