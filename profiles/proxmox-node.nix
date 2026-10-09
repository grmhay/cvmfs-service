# Profile `proxmox-node`: labservera..labserverd (Saddlehorn2 cluster).
{ pkgs, inputs, system }:
with pkgs; [
  smartmontools
  nvme-cli
]
