{
  description = "Homelab NixOS hosts — Pterodactyl Wings game-server nodes.";

  # Pinned to a release channel, with flake.lock committed, so a
  # `nixos-rebuild switch` months from now builds what was tested.
  # Bump deliberately: `task nix:update`, then `task nix:check`.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";

      # Every Wings node is the same machine wearing a different name,
      # IP and port range — so a host contributes one directory and
      # nothing else. Adding node #2 is: copy hosts/wings1/ to
      # hosts/wings2/, edit the three values at the top of its
      # default.nix, paste in its generated hardware.nix, and add one
      # line to nixosConfigurations below.
      mkWingsHost = hostDir: nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          ./modules/base.nix
          ./modules/wings.nix
          hostDir
        ];
      };
    in
    {
      nixosConfigurations = {
        wings1 = mkWingsHost ./hosts/wings1;
      };

      # Exposed so the Wings derivation can actually be BUILT, not just
      # evaluated. `nix flake check` never builds, so a wrong hash in
      # pkgs/wings.nix would pass it and only fail on the host partway
      # through a deploy. `task nix:check` builds this output for that
      # reason.
      packages.${system}.wings =
        (import nixpkgs { inherit system; }).callPackage ./pkgs/wings.nix { };
    };
}
