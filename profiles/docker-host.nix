# Profile `docker-host`: skyline and any other compose-stack host.
# vm-service's standalone binary moves here in phase 3 (inputs.vm-service).
{ pkgs, inputs, system }:
with pkgs; [
  dive
  lazydocker
]
