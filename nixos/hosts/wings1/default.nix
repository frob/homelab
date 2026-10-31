## wings1 — Pterodactyl Wings node #1.
##
## Everything host-specific lives in the block at the top. A second node
## is this directory copied, those values changed, and its own generated
## hardware.nix pasted in beside it.
{ config, lib, pkgs, ... }:

{
  imports = [ ./hardware.nix ];

  # --- The per-host block ------------------------------------------
  networking.hostName = "wings1";

  # Static IP, same shape as the Debian hosts' network_* vars in
  # host_vars/. Proxmox VMs in this homelab come up as ens18.
  networking.useDHCP = false;
  networking.interfaces.ens18.ipv4.addresses = [{
    address = "192.168.1.60";
    prefixLength = 24;
  }];
  networking.defaultGateway = "192.168.1.1";
  networking.nameservers = [ "192.168.1.1" ];

  homelab.wings = {
    enable = true;
    apiPort = 8080;
    sftpPort = 2022;
    # Keep in step with the allocations you create for this node in the
    # panel — a port the panel hands out but this list doesn't cover is
    # open in the panel and closed on the host.
    gamePortRanges = [{ from = 25500; to = 25600; }];
  };

  # --- Don't change this on an existing host -----------------------
  # Set to the NixOS release the box was first installed with, and left
  # alone forever after; it's what lets stateful-service defaults stay
  # compatible across upgrades.
  system.stateVersion = "25.05";
}
