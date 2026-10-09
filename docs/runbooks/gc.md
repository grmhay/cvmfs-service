# Runbook: repository garbage collection (not before year two)

Retention policy: nothing is deleted from the repository in its first year. When that changes:

1. Enumerate what every Channel still references:
   `for l in /cvmfs/nix.hayweb.org/profiles/*/*/*; do readlink "$l"; done | sort -u` — then the
   closure of each via `nix path-info -r --store local?root=/cvmfs/nix.hayweb.org`.
2. Anything outside those closures is a candidate. Remove it **only** from the Lower Store and the
   Binary Cache inside one transaction; never touch `/profiles`.
3. Then reclaim objects on the Origin: `cvmfs_server gc -r 0 nix.hayweb.org` (requires
   `CVMFS_AUTO_GC` or `CVMFS_GARBAGE_COLLECTION=true` in `server.conf` at mkfs time — check).
4. Union-mode hosts never cached a deleted path in the RW Branch (they never copy), so no host
   state needs cleaning. Cache-mode hosts keep their local copies until their own GC.
