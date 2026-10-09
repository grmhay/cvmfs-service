# Profile `builder`: pi5 / pi6 (aarch64 remote builders) and the Publisher.
{ pkgs, inputs, system }:
with pkgs; [
  nix-output-monitor
  nix-tree
  git
]
