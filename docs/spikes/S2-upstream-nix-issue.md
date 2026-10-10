# Upstream Nix fix: draft issue and PR (not filed)

Status: the fix is on the fork branch
[`grmhay/nix:chroot-parent-fuse-traverse`](https://github.com/grmhay/nix/tree/chroot-parent-fuse-traverse)
(based on NixOS/nix master `9bf3582`) and is proven on the spike VMs (results below). Nothing has been opened on NixOS/nix. The
issue and PR text must be rewritten by hand before submission: Nix's contribution policy requires
human-authored issue/PR descriptions and an `Assisted-by:` commit trailer for AI-assisted code
(`CONTRIBUTING.md`, "Automation/AI policy").

## Correction to the first draft

The first draft proposed making `<drv>.chroot` `0710 root:<build gid>`. That is unsafe. Classic
build users (`nixbld1`..`N`) all share the `nixbld` group, and inside the chroot both `root/`
(0750 root:nixbld) and `root/nix/store` (01775 root:nixbld) are group-accessible; the latter is
group-*writable*. With a group-traversable parent, a concurrent unsandboxed build running as another
`nixbld` user could read another build's chroot and create files in its `nix/store`, i.e. plant an
output path before the real build writes it. The 0700 parent is what prevents that today.

The fix on the branch instead makes the parent **`0100 <build uid>:<build gid>`**
(execute-only for that one UID; the group gets nothing). Only that build's UID (and root) can
traverse it; nobody can list it without first chmod'ing it, which only the owner could do, and the
owner is the build itself.

The group must be the build group, not root. The first attempt (`<build uid>:root`, commit
`e000ca5`) broke **every** sandboxed build, plain stores included, with
`unable to bind mount "<drv>.chroot/root": Permission denied`. The process that sets up the chroot
runs as host root inside the builder's user namespace, where only the build uid/gid are mapped. It is
no longer the owner, and `CAP_DAC_OVERRIDE` in a user namespace only applies to inodes whose owner
**and** group are mapped there. The fixup commit `86eccc2` uses the build group. Squash the two before
submitting; the fixup message explains the reason, which belongs in the PR or a code comment.

## Notes for the human rewrite

- **Where:** `src/libstore/unix/build/chroot.cc`, `setupBuildChroot()`, right after
  `createDir(chrootParentDir, 0700)`. Shared by Linux and FreeBSD.
- **Why it only bites on FUSE:** after `pivot_root()` a kernel filesystem resolves paths from the
  `root/` inode and never re-checks `.chroot`. mergerfs (and other path-based FUSE filesystems)
  receive the full host path and re-resolve it on the backing branch as the caller (`setfsuid`). There
  is no mergerfs option to avoid that (its docs say it always runs as the caller), and the chroot's
  location is not configurable (`build-dir` moves only the build directory).
- **uid-range / auto-allocate-uids:** the builder runs as the first UID of the range (sandbox uid 0),
  which is `getUID()`, so the owner matches. Processes that switch to other UIDs of the range inside
  the sandbox would still fail on a FUSE store; untested, worth a sentence.
- **Owner can chmod:** the build UID owns the directory and could chmod it, but it can only name the
  path from the host mount namespace, and the UID is locked to this build while it runs.
- **Who is affected:** anyone with the store directory on a path-based FUSE filesystem: mergerfs
  union stores (our case, with `local-overlay-store` and `check-mount=false`), probably also
  unionfs-fuse, and some network FUSE filesystems. Links to issues of that kind would help.
- **Tests upstream would want:** a NixOS VM test (`tests/nixos/`) that mounts a mergerfs union, points
  a store's real directory into it, and runs a sandboxed build with build users. A functional test
  cannot use FUSE inside the Nix sandbox.
- **Release note:** probably `doc/manual/rl-next/<name>.md`, short, "sandboxed builds now work when
  the store is on a path-based FUSE filesystem".

## Proof on the spike VMs (2026-10-09)

`spikes/s2-nix-chroot-fix.sh <nix-cli out path>` runs `nix-daemon` from a given build against the
union store and checks the cases below. Both builds are `nix-cli` from the same base commit
(`9bf3582`), built on spike-deb1, run on spike-deb1 (Debian 13, kernel 6.12.111, ext4) and
spike-rhel1 (RHEL 10.2, kernel 6.12.0-211, xfs), both with mergerfs 2.40.2. Identical results on both:

| Check | master `9bf3582` | fix `86eccc2` |
|---|---|---|
| minimal sandboxed build on the union | FAIL (`executing '/bin/sh': No such file or directory`) | ok |
| long-running sandboxed build on the union | FAIL | ok |
| `nixpkgs#hello` rebuilt in the sandbox (inputs on both branches) | FAIL (`executing '…bash': No such file or directory`) | ok |
| sandboxed build with `auto-allocate-uids` | FAIL | ok |
| sandboxed build in a chroot store on its own mergerfs mount (no `local-overlay`) | FAIL | ok |
| sandboxed build on a plain ext4/xfs store (regression check) | ok | ok |
| chroot parent during a build | 0700 root:root | `100 nixbld1:nixbld` |
| another build user (`nixbld2`) lists `<drv>.chroot/root`, via the branch and via the union | — | denied |
| the build user lists `<drv>.chroot` | — | denied (traverse only) |

The chroot-store-on-mergerfs case shows the bug is not specific to `local-overlay-store`: any store
whose real directory is on mergerfs hits it.

Not tested: derivations with `uid-range` (`requiredSystemFeatures = [ "uid-range" ]`, needs
`use-cgroups`), FreeBSD, the upstream test suites (only `nix-cli` was built; no unit, functional or
NixOS tests were run). There is no KVM on the spike VMs, so the NixOS test below is unrun.

## NixOS VM test sketch (unrun)

Modelled on `tests/nixos/chroot-store.nix`; the same shape as check 6 of the spike script. Register
it in `tests/nixos/default.nix`.

```nix
{ config, ... }:
let
  pkgs = config.nodes.machine.nixpkgs.pkgs;
in
{
  name = "fuse-store-sandbox";

  nodes.machine = { pkgs, ... }: {
    virtualisation.writableStore = true;
    environment.systemPackages = [ pkgs.mergerfs ];
    nix.settings.experimental-features = [ "nix-command" ];
  };

  testScript = ''
    start_all()
    machine.succeed("mkdir -p /srv/branch /srv/union")
    machine.succeed("mergerfs -o allow_other,category.create=ff /srv/branch /srv/union")
    # The store's real directory is on mergerfs; the builder runs as a nixbld user.
    machine.succeed(
      "nix build --offline --store /srv/union/root --option sandbox true "
      "--option build-users-group nixbld --expr "
      "'builtins.derivation { name = \"t\"; system = \"${pkgs.stdenv.hostPlatform.system}\"; "
      "builder = \"/bin/sh\"; args = [ \"-c\" \"echo hi > $out\" ]; }'"
    )
  '';
}
```

Open question for the rewrite: whether `/bin/sh` is available in the test VM's sandbox
(`sandbox-paths`), as it is on Debian/RHEL installs where Nix is built with a sandbox shell.

## Draft PR text (rewrite before opening; base `NixOS/nix:master`)

**Title:** libstore: let the build user traverse the chroot parent directory

**Motivation.** Sandboxed builds fail with ENOENT for every path when the store directory is on a
path-based FUSE filesystem such as mergerfs. Nix creates the chroot at `<store>/<drv>.chroot` (0700
root). After `pivot_root` a kernel filesystem never re-checks that directory, but mergerfs re-resolves
the full host path as the calling user, and the build user cannot traverse it. Fixes #<issue>.

**Change.** The parent becomes `0100 <build uid>:<build gid>`: traversable by this build's user only.
Not group-traversable, because classic build users share `nixbld` and `root/nix/store` is
group-writable. The group must still be the build group so the namespaced setup process keeps
`CAP_DAC_OVERRIDE` on the directory.

**Testing.** <spike results above, plus the NixOS test once it runs>.

**AI disclosure.** <how the tool was used; the commit carries `Assisted-by:`>.

## Draft issue text (rewrite before filing)

**Title:** Sandboxed builds fail when the store is on a path-based FUSE filesystem (mergerfs):
`<drv>.chroot` is 0700

**Describe the bug.** With `/nix/store` on mergerfs (union of a local RW dir and a read-only lower
store, `local-overlay-store` with `check-mount=false`), every sandboxed build fails with ENOENT inside
the sandbox (`executing '/bin/sh': No such file or directory`); unsandboxed builds work. The chroot
parent `<store>/<drv>.chroot` is 0700 root. mergerfs re-resolves each path on its branches as the
calling uid, so the build user cannot traverse `.chroot`.

**Steps to reproduce** (Nix 2.30.0 and 2.35.2, mergerfs 2.40.2, Linux 6.12/6.18, x86_64 and aarch64):

1. `mergerfs -o category.create=ff,allow_other /nix/.rw-store/store=RW:/srv/lower/nix/store=RO /nix/store`
2. `nix-daemon --option store 'local-overlay://?lower-store=local%3Froot%3D%2Fsrv%2Flower%26read-only%3Dtrue&upper-layer=/nix/.rw-store/store&check-mount=false'`
3. `nix build --impure --expr 'derivation { name = "t"; system = builtins.currentSystem; builder = "/bin/sh"; args = [ "-c" "echo hi > $out" ]; }'`

Confirmations: without Nix, a 0700 dir with a 0750 root:nixbld child, bind-mounted and read as
`nixbld1`, works on xfs and gives ENOENT on mergerfs. Chmod'ing `.chroot` as it appears makes the
build succeed, as does `build-users-group =`. A fork with the proposed fix passes on Debian 13 and
RHEL 10: <link>.

**Expected behavior.** Sandboxed builds work on any filesystem Nix can otherwise use as a store.
