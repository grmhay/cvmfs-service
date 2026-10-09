# Profile `base`: every host in the fleet, including the Pis.
# Keep this small — it is on PATH everywhere and a collision here breaks
# every Group build. Tooling only; no services.
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
]
