{
  description = "Fleet software distribution: Nix profiles published to the CVMFS repository nix.hayweb.org.";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    ## Service packages enter the fleet as pinned flake inputs (ADR 0001).
    ## Renovate bumps the tag; the publisher builds and publishes the result.
    ## vm-service keeps its own nixpkgs: its build runs its lint gate, and our
    ## newer ruff fails v0.1.0 on rules it did not ship with.
    vm-service.url = "github:grmhay/vm-service/v0.1.0";
    vm-service.inputs.flake-utils.follows = "flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, ... }@inputs:
    let
      ## Only Linux is a distribution target. Darwin can still `nix develop`
      ## via the devShell below, which is defined for every default system.
      fleetSystems = [ "x86_64-linux" "aarch64-linux" ];

      ## Host Groups (CONTEXT.md). One composite Profile is built per Group;
      ## file collisions between its packages fail at build time, not on PATH.
      groups = [ "base" "docker-host" "proxmox-node" "cloud" "builder" ];

      repository = "nix.hayweb.org";
    in
    flake-utils.lib.eachSystem fleetSystems (system:
      let
        pkgs = import nixpkgs { inherit system; };

        ## profiles/<group>.nix returns the package list for that Group.
        ## Every Group includes `base` so a host never needs two PATH entries.
        profileFor = group:
          let
            own = import (./profiles + "/${group}.nix") { inherit pkgs inputs system; };
            base = if group == "base" then [ ] else import ./profiles/base.nix { inherit pkgs inputs system; };
          in
          pkgs.buildEnv {
            name = "profile-${group}";
            paths = base ++ own;
            pathsToLink = [ "/bin" "/share" "/lib" "/etc" ];
            ignoreCollisions = false;
          };

        profiles = nixpkgs.lib.listToAttrs (map
          (g: { name = "profile-${g}"; value = profileFor g; })
          groups);

        ## Publishing tools run on the Publisher (masterkey-escrow excepted);
        ## they wrap the scripts in publish/ with their runtime dependencies pinned.
        mkApp = name: runtimeInputs: {
          type = "app";
          program = "${pkgs.writeShellApplication {
            inherit name runtimeInputs;
            text = ''
              export CVMFS_REPOSITORY="''${CVMFS_REPOSITORY:-${repository}}"
              export FLEET_GROUPS="''${FLEET_GROUPS:-${builtins.concatStringsSep " " groups}}"
              export FLEET_SYSTEMS="''${FLEET_SYSTEMS:-${builtins.concatStringsSep " " fleetSystems}}"
              # The scripts live in the store; the flake to build is the checkout
              # the app is run from (the Publisher's clone, or a dev tree).
              export PUBLISH_FLAKE="''${PUBLISH_FLAKE:-$PWD}"
              # Pinned with the scripts, not read from the flake being built.
              export CVMFS_DIRTAB="''${CVMFS_DIRTAB:-${./server/cvmfs/cvmfsdirtab}}"
              exec ${./publish}/${name}.sh "$@"
            '';
          }}/bin/${name}";
        };
      in
      {
        packages = profiles // { default = profiles.profile-base; };

        apps = {
          publish = mkApp "publish" [ pkgs.nix pkgs.git pkgs.jq pkgs.coreutils pkgs.findutils pkgs.sqlite ];
          promote = mkApp "promote" [ pkgs.nix pkgs.git pkgs.jq pkgs.coreutils ];
          verify-origin = mkApp "verify-origin" [ pkgs.curl pkgs.openssl pkgs.jq pkgs.coreutils pkgs.gnused pkgs.gnugrep ];
          ## Runs on the workstation, not the Publisher: moves the master key
          ## that mkfs leaves behind into ansible/secrets/ (docs/runbooks/publisher-bootstrap.md).
          masterkey-escrow = mkApp "masterkey-escrow" [ pkgs.sops pkgs.openssh pkgs.coreutils pkgs.gnused ];
          ## Reads a .cvmfswhitelist on stdin and prints its expiry (#20). The
          ## probe on skyline (homelab-opscontrolplane) runs a vendored copy.
          whitelist-expiry = mkApp "whitelist-expiry" [ pkgs.gawk pkgs.coreutils ];
        };

        ## `nix flake check` builds every Profile for the host system and
        ## evaluates them for the other one (CI has no aarch64 builders;
        ## the Publisher does the real aarch64 build before publishing).
        checks = profiles // {
          ## The docker-host Profile carries vm-service's CLI and it runs.
          docker-host-vm-service = pkgs.runCommand "docker-host-vm-service" { } ''
            ${profiles.profile-docker-host}/bin/vm_service --help > $out
          '';
          ## The whitelist parser's tests (#20) run with busybox alone on PATH,
          ## because the probe container that runs it has no GNU userland either.
          whitelist-expiry = pkgs.runCommand "whitelist-expiry-tests" { } ''
            PATH=${pkgs.busybox}/bin ROOT=${./.} sh ${./tests/whitelist-expiry.sh}
            touch $out
          '';
          ## The Publisher's unattended resign wrapper (#19), against real
          ## sops/age and a stub cvmfs_server: success, failures, cleanup, the publish lock.
          resign-wrapper = pkgs.runCommand "resign-wrapper-test"
            { nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.gnused pkgs.diffutils pkgs.sops pkgs.age pkgs.util-linux ]; }
            ''
              cp ${./ansible/roles/cvmfs_publisher/files/cvmfs-resign.sh} cvmfs-resign.sh
              cp ${./tests/cvmfs-resign-test.sh} cvmfs-resign-test.sh
              chmod +x cvmfs-resign.sh cvmfs-resign-test.sh
              patchShebangs .
              HOME="$TMPDIR" ./cvmfs-resign-test.sh ./cvmfs-resign.sh
              touch $out
            '';
          ## The publish reconciler's git fetch retry (#26), with stub git and nix:
          ## a fetch that fails then succeeds publishes; one that keeps failing fails the run.
          reconcile-publish = pkgs.runCommand "reconcile-publish-test"
            { nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.util-linux ]; }
            ''
              cp ${./publish/reconcile-publish.sh} reconcile-publish.sh
              cp ${./tests/reconcile-publish-test.sh} reconcile-publish-test.sh
              chmod +x reconcile-publish.sh reconcile-publish-test.sh
              patchShebangs .
              HOME="$TMPDIR" ./reconcile-publish-test.sh ./reconcile-publish.sh
              touch $out
            '';
          ## The catalog layout (#44): Nix's verify and GC leave a marker at the
          ## Lower Store's /nix alone, remove one in /nix/store, and catch one in a path.
          store-catalog-marker = pkgs.runCommand "store-catalog-marker-test"
            { nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.nix ]; }
            ''
              cp ${./tests/store-catalog-marker-test.sh} store-catalog-marker-test.sh
              chmod +x store-catalog-marker-test.sh
              patchShebangs .
              HOME="$TMPDIR" ./store-catalog-marker-test.sh
              touch $out
            '';
          ## Leaving union Mode for cache Mode fetches every Lower Store path the
          ## store still lists (#29 criterion 6), on a throwaway store and a file:// cache.
          fill-missing-paths = pkgs.runCommand "fill-missing-paths-test"
            { nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.nix ]; }
            ''
              cp ${./ansible/roles/nix_union_store/files/fill-missing-paths.sh} fill-missing-paths.sh
              cp ${./tests/fill-missing-paths-test.sh} fill-missing-paths-test.sh
              chmod +x fill-missing-paths.sh fill-missing-paths-test.sh
              patchShebangs .
              HOME="$TMPDIR" ./fill-missing-paths-test.sh ./fill-missing-paths.sh
              touch $out
            '';
          ## publish.sh's cleanup of the old per-path markers (#44), on a fixture store.
          drop-path-catalogs = pkgs.runCommand "drop-path-catalogs-test"
            { nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.findutils ]; }
            ''
              cp ${./publish/drop-path-catalogs.sh} drop-path-catalogs.sh
              cp ${./tests/drop-path-catalogs-test.sh} drop-path-catalogs-test.sh
              chmod +x drop-path-catalogs.sh drop-path-catalogs-test.sh
              patchShebangs .
              HOME="$TMPDIR" ./drop-path-catalogs-test.sh ./drop-path-catalogs.sh
              touch $out
            '';
        };
      })
    // flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          ## nixpkgs marks mc insecure because upstream abandoned it. It is the
          ## workstation's MinIO admin client (server/minio/RUNBOOK.md), which
          ## awscli2 and rclone cannot replace; permitted at this version only,
          ## so a bump that changes it fails here again.
          config.permittedInsecurePackages = [ "minio-client-2025-08-13T08-35-41Z" ];
        };
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            ansible
            ansible-lint
            sops
            age
            minio-client
            jq
            shellcheck
            yamllint
          ];
        };
      });
}
