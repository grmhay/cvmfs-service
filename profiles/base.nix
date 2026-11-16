# Profile `base`: every host in the fleet, including the Pis.
# Keep this small — it is on PATH everywhere and a collision here breaks
# every Group build. Tooling and the homelab services' CLIs; no daemons.
{ pkgs, inputs, system }:
with pkgs; [
  ripgrep
  fd
  jq
  yq-go
  htop
  tmux
  sops
  age
  curl
  rsync
] ++ [
  # The homelab services' CLIs, pinned by tag in flake.nix (ADR 0001). Each
  # also brings its -api and -mcp entry points; nothing starts them here.
  inputs.packer-service.packages.${system}.packer-service
  inputs.dhcp-service.packages.${system}.dhcp-service
  inputs.dns-service.packages.${system}.dns-service
]
