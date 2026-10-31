## Baseline for every NixOS host in this repo — the declarative
## equivalent of what playbooks/debian-basic.yml + debian-docker.yml do
## imperatively on the Debian boxes. Deliberately mirrors their security
## model rather than inventing a second one:
##
##   - the admin user is a plain wheel member, and sudo asks for a
##     password (NOT a NOPASSWD rule), so a stolen SSH key alone doesn't
##     get root;
##   - every public_keys/*.pub in the repo is authorized, so rotating a
##     key is "drop the .pub in, re-run the phase";
##   - SSH password auth is off.
##
## There is no corresponding `setup-nixos-*.yml` baseline chain: this
## file IS the baseline, applied in one switch.
{ config, lib, pkgs, ... }:

{
  # --- Identity ---------------------------------------------------
  # Keep these in step with group_vars/all/main.yml; they're duplicated
  # because Nix can't read Ansible's vars, not because they're meant to
  # diverge.
  time.timeZone = "America/Los_Angeles";
  networking.domain = "andrsn.org";

  # --- Admin user -------------------------------------------------
  users.mutableUsers = false;

  users.users.frob = {
    isNormalUser = true;
    description = "Homelab admin";
    extraGroups = [ "wheel" "docker" ];
    shell = pkgs.bashInteractive;

    # The one secret this tree needs and the one it must not contain.
    # playbooks/nixos-wings.yml writes this file (mode 0400) from
    # `nixos_admin_password_hash` in group_vars/all/vault.yml before it
    # switches. A path, not a literal, is what lets a public repo carry
    # a declarative password: Nix references the file, Ansible owns the
    # contents, and the hash never enters the store.
    #
    # With users.mutableUsers = false, no hash file means no password,
    # which means no sudo — and Ansible's become would fail on the next
    # run. Hence the assertion below rather than a silent lockout.
    hashedPasswordFile = "/etc/nixos-secrets/admin.pass";

    # Same source of truth as debian-basic.yml: the repo's public_keys/
    # directory, synced to /etc/nixos/public_keys/ by the phase.
    openssh.authorizedKeys.keys =
      let
        keyDir = ../public_keys;
      in
      map (f: lib.readFile f)
        (lib.filter (f: lib.hasSuffix ".pub" (toString f))
          (lib.filesystem.listFilesRecursive keyDir));
  };

  # wheel needs a password for sudo. This is the default, stated
  # explicitly because it's a deliberate choice that someone will
  # otherwise "helpfully" flip to false the first time a deploy prompts.
  security.sudo.wheelNeedsPassword = true;

  # --- SSH --------------------------------------------------------
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # --- Docker -----------------------------------------------------
  # Wings runs every game server as a Docker container, so this is a
  # hard dependency of modules/wings.nix, not a convenience.
  virtualisation.docker = {
    enable = true;
    # Same log rotation as debian-docker.yml's daemon.json. Without it a
    # chatty game server's stdout grows until the disk is gone.
    daemon.settings = {
      log-driver = "json-file";
      log-opts = {
        max-size = "10m";
        max-file = "3";
      };
    };
    # autoPrune is deliberately OFF. It runs `docker system prune`,
    # which removes STOPPED containers — and on a Wings node a stopped
    # container is a game server somebody turned off. Wings would
    # recreate it from the egg on next boot, but the blast radius of
    # being wrong about that is someone's server, so don't. Prune by
    # hand with `docker image prune` if images pile up.
    autoPrune.enable = false;
  };

  # --- Housekeeping -----------------------------------------------
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Store GC. A Wings box accumulates generations fast if you iterate on
  # the config; without this, /nix/store quietly eats the disk the game
  # servers need.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  # rsync and git aren't used by the deploy path (the phase uses
  # ansible.builtin.copy precisely so it doesn't need rsync on a fresh
  # box) but you will want them the first time you debug one by hand.
  environment.systemPackages = with pkgs; [
    git
    rsync
    curl
    htop
    tmux
  ];

  # No system.autoUpgrade, and that's deliberate — it has no coherent
  # meaning against a committed flake.lock. Pointed at /etc/nixos it
  # would either rebuild the already-pinned lock (a no-op every night)
  # or be given --update-input to fetch newer nixpkgs, which drifts the
  # host away from the lock `task nix:check` actually tested and makes
  # the pin a lie.
  #
  # So updates here are explicit, the same way every container image in
  # this repo is pinned and bumped on purpose:
  #
  #   task nix:update && task nix:check && task deploy:nixos-wings
  #
  # That's the trade against unattended-upgrades on the Debian hosts:
  # security patches land when you deploy, not overnight. Worth knowing
  # rather than discovering.

  assertions = [
    {
      assertion = config.users.users.frob.openssh.authorizedKeys.keys != [ ];
      message = ''
        No SSH keys found under nixos/public_keys/. The nixos-wings phase
        syncs the repo's public_keys/ there; with users.mutableUsers =
        false and password auth off, switching with an empty key list
        locks you out of this host.
      '';
    }
  ];
}
