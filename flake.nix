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
          publish = mkApp "publish" [ pkgs.nix pkgs.git pkgs.jq pkgs.coreutils pkgs.sqlite ];
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
        };
      })
    // flake-utils.lib.eachDefaultSystem (system:
      let pkgs = import nixpkgs { inherit system; };
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
