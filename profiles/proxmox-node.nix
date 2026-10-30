# Profile `proxmox-node`: both Proxmox clusters, Saddlehorn (labserver5..labserver7, PVE 8) and
# Saddlehorn2 (labservera..labserverd, PVE 9). labserver3/4 are being decommissioned and get no Profile.
{ pkgs, inputs, system }:
with pkgs; [
  smartmontools
  nvme-cli
]
