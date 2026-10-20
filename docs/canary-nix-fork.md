# Canary-only Nix fork: the chroot-parent fix on 2.30.0 (#14)

Union Store hosts run with the Nix sandbox off, because Nix creates the build chroot's parent
`0700 root:root` and mergerfs re-resolves every path inside it as the build user (spike S2,
ADR 0002). The fix makes that parent `0100 <build uid>:<build gid>`. Fleet-wide, it waits for an
upstream release (#6, #9, #13). #6 was amended on 2026-10-19 to allow one exception: a fork build
on the `nix-canary` hosts only (`pi7`, `nixcanary-deb1`, `nixcanary-rhel1`), for soak time and
evidence for the upstream PR.

## The fork

Branch `grmhay/nix:chroot-fix-2.30.0`: one commit on the `2.30.0` tag, the release that the
role's installer pin (3.8.0) installs.

- `src/libstore/unix/build/linux-derivation-builder.cc`: after creating `<drv>.chroot`, chown it
  to the build user and build group and chmod it `0100`. This is a backport of `e000ca5` +
  `86eccc2` from `chroot-parent-fuse-traverse`, which is based on master and is what #9 submits.
- `.version`: `2.30.0+chrootfix`, so `nix --version` and `nix store info` tell the fork from
  stock 2.30.0. The role's gate keys on this suffix.

Build the full `nix` package (it carries the systemd units the installer links through the
default profile), natively on a host of each system:

```sh
git archive --format=tar --prefix=nix-src/ chroot-fix-2.30.0 | ssh <host> 'tar -xf - -C ~'
ssh <host> 'nix --extra-experimental-features "nix-command flakes" build --no-link --print-out-paths \
  "path:$HOME/nix-src#packages.<x86_64-linux|aarch64-linux>.default"'
```

On 2 GB hosts, add `--cores 1 --max-jobs 1`. The full package runs Nix's unit and functional tests:
19 minutes on `nixcanary-deb1` with one core, and 90 minutes on `pi7`, a Raspberry Pi 4.

## Installing it on a canary

No binary cache or signing key. If the fork was built on another host, stream its closure to the
canary, then switch the default profile on it as root:

```sh
ssh <build host> "nix-store --export \$(nix-store -qR <store path>)" | ssh root@<canary> 'nix-store --import'
ssh root@<canary> '~/cvmfs-service/spikes/canary-nix-fork.sh install <store path>'
```

`canary-nix-fork.sh install` replaces only the `nix` element of the default profile, as
`nix upgrade-nix` does, so `nss-cacert` and the Union Store stay as they are. It then restarts the
daemon and checks that the daemon reports the fork. `rollback` returns to the previous profile
generation.

## Turning the sandbox on

Set these for the host only, through NetBox or inventory, never in a playbook:

```yaml
nix_sandbox_fork: true
nix_union_sandbox: "true"
```

`sandbox_gate.yml` then accepts an installed Nix whose version ends in `nix_sandbox_fork_suffix`
(`+chrootfix`). Without `nix_sandbox_fork`, or with stock Nix installed, `"true"` is still
refused. The run ends with the sandboxed smoke build (`smoke.yml`).

## Leaving the fork

When a Nix release with the fix exists (#13), bump `nix_installer_version` to an installer
that installs it and set `nix_sandbox_fix_version`. Then remove `nix_sandbox_fork` and run the
role. The upgrade task moves the canary from the 2.30.0-based fork to that release, because
2.30.0 is older than the new pin.

Bumping the pin before such a release exists also replaces the fork with stock Nix. The gate then
refuses `"true"` until the fork is rebuilt on the new base, or the host goes back to `"false"`.

## Results (2026-10-19)

The fork is commit `bf11bc8` on `grmhay/nix:chroot-fix-2.30.0`.

| Canary | System | Fork store path |
|---|---|---|
| `nixcanary-deb1` | Debian 13, x86_64 | `/nix/store/jx3nc5b4ahdk1m7a0829zsl5c2p4953l-nix-2.30.0+chrootfix` (built here) |
| `nixcanary-rhel1` | RHEL 10.2, x86_64 | the same path, imported from `nixcanary-deb1` |
| `pi7` | Debian 13, aarch64 (Pi 4) | `/nix/store/3n9cydqz3sgnvdzx2rzisxy8yqx0kqv9-nix-2.30.0+chrootfix` (built here) |

None of the three ran a Union Store before, and no Repository exists yet. Each now runs union Mode
over the stand-in Lower Store at `/srv/lower` (`spikes/union-standin.sh`, `spikes/union-standin.yml`),
with `nix_union_sandbox: "true"` and `nix_sandbox_fork: true`.

On all three:

| Check | Result |
|---|---|
| `nix --version` and the daemon | `2.30.0+chrootfix`; `nss-cacert` kept in the default profile |
| Role run, union Mode, `"true"` + `nix_sandbox_fork` | gate passes ("canary fork, +chrootfix"); smoke build passes |
| Second role run | `changed=0`; the fork stays |
| `"true"` with `nix_sandbox_fork: false` | refused by the gate, `changed=0` |
| `spikes/s2-nix-chroot-fix.sh --installed` | 10 passed, 0 failed |

The acceptance checks: a minimal and a long-running sandboxed build; `nixpkgs#hello` rebuilt in the
sandbox; `auto-allocate-uids`; a chroot store on its own mergerfs mount; a plain-store regression
check. The security checks: the chroot parent is `0100` owned by the build user (`nixbld1`), another
build user (`nixbld2`) cannot traverse the chroot through the backing directory or the union, and the
build user can traverse its parent but not list it.

On `nixcanary-deb1`, `"false"` with the flag unset turned the sandbox off and left the union and the
fork daemon in place. `"true"` with the flag turned it back on.

### Notes from the rollout

- **The settings are not in NetBox yet.** The runs passed `nix_union_sandbox` and `nix_sandbox_fork`
  with `-e`. Until NetBox sets them for the `nix-canary` tag (ansible-lab-config#113), a role run from
  the production inventory puts the canaries back on the default `"false"`. The fork binary stays.
- **pi7's store was half gone.** After spike S2 returned it to a plain store, most paths had
  disappeared while the database still listed them, so evaluation failed. `nix-store --verify
  --repair` fixed it.
- **`nixcanary-rhel1` needs root over SSH.** The `ansible` user has a passwordless sudo rule, but a
  later `wheel` rule that asks for a password overrides it.
- **Restarting the daemon:** stop `nix-daemon.service` and `nix-daemon.socket`, then start both.
  Restarting the socket while the service it triggered still runs is refused.
