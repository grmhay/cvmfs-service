# Profile `cloud`: public-cloud hosts reached over OpenVPN.
{ pkgs, inputs, system }:
with pkgs; [
  wireguard-tools
  mtr
]
