# Profile `docker-host`: skyline and any other compose-stack host.
{ pkgs, inputs, system }:
let
  # vm-service's CLI (`vm_service`), pinned by tag in flake.nix (ADR 0001).
  # v0.1.0's flake omits setuptools-scm from build-system, and a flake source
  # has no .git to derive a version from; vm-service main fixes both. Drop
  # this override when the pinned tag carries that fix.
  # Built against vm-service's own nixpkgs, so its setuptools-scm comes from there.
  vmPkgs = inputs.vm-service.inputs.nixpkgs.legacyPackages.${system};
  vm-service = inputs.vm-service.packages.${system}.vm-service.overridePythonAttrs (old: {
    build-system = (old.build-system or [ ]) ++ [ vmPkgs.python3Packages.setuptools-scm ];
    env = (old.env or { }) // {
      SETUPTOOLS_SCM_PRETEND_VERSION = "0.0.0+g${inputs.vm-service.shortRev}";
    };
  });
in
with pkgs; [
  dive
  lazydocker
  vm-service
]
