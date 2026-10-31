## PLACEHOLDER — replace this file with the real thing before the first
## switch on a new host.
##
## A nixosSystem will not even *evaluate* without a bootloader and a
## root fileSystems entry, so `task nix:check` needs something here.
## This is a plausible default for a NixOS 25.05 UEFI install on a
## single-disk Proxmox VM — not a guess about *your* disk.
##
## To make it real, on the host:
##
##   nixos-generate-config --show-hardware-config
##
## and paste the output over everything below. scripts/nixos-bootstrap.sh
## prints it for you as its last step.
##
## playbooks/nixos-wings.yml guards this: before switching it checks that
## every /dev/disk/by-* path named in this file actually exists on the
## target, so a forgotten replacement fails with a readable message
## instead of producing an unbootable generation.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [ ];

  boot.initrd.availableKernelModules = [
    "ahci"
    "xhci_pci"
    "virtio_pci"
    "virtio_scsi"
    "sd_mod"
    "sr_mod"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-intel" ];
  boot.extraModulePackages = [ ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/BOOT";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  swapDevices = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
