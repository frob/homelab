# CLAUDE.md

Notes for AI agents (and humans) working in this repo.

## Hard rules

- **Everything runs in containers.** The host workstation needs only
  Docker and [go-task](https://taskfile.dev). No Python, Ansible,
  ansible-lint, or galaxy collections installed on the host. The
  Ansible runner image is defined by `Dockerfile` and built/used via
  `docker-compose.yml`.
- **All tasks go through the Taskfile.** Don't suggest or run raw
  `ansible-playbook`, `ansible-lint`, `docker compose`, or
  `ansible-galaxy` commands. If a workflow doesn't have a Task, add
  one in `Taskfile.yml` rather than running it ad-hoc.

## Layout

- `setup-debian.yml` — bootstrap playbook for fresh VMs in `[init]`.
  Imports every baseline phase.
- `setup-<role>.yml` — per-role playbooks (`docker`, `gpu`,
  `jellyfin`, `pterodactyl`, `nixos-wings`).
  Each imports the full baseline and then layers the role-specific
  phase on top. Re-runs the whole stack idempotently — the "ansibly"
  way — so a role deploy can recover a box without remembering which
  phases it's seen. `setup-nixos-wings.yml` is the exception: see
  **NixOS hosts** below.
- `playbooks/<os>-<phase>.yml` — one playbook per phase. The prefix
  names the OS family it targets: `debian-*` (init, basic, network,
  docker, portainer-agent, cockpit, gpu, jellyfin, nfs-media,
  syncthing, pterodactyl-panel) and `nixos-*` (wings). Each is
  independently runnable via its own `deploy:*` task. Every phase
  uses `hosts: "{{ target_hosts | default('init') }}"` so the same
  file is reusable across role groups.
- `nixos/` — the flake that configures the NixOS hosts: `flake.nix`
  (one `nixosConfigurations` entry per host), `modules/base.nix` (the
  declarative baseline), `modules/wings.nix` (the Wings service),
  `pkgs/wings.nix` (the Wings package — nixpkgs has none), and
  `hosts/<name>/` per machine.
- `group_vars/all.yml` — defaults shared by every host group
  (admin user, timezone, docker daemon config, portainer-agent).
- `group_vars/<group>.yml` — per-group overrides
  (`init` for bootstrap identity/IP, `gpu`/`jellyfin`/`pterodactyl`
  for role knobs; `nixos_wings` holds almost nothing, because the
  flake owns that host's state, not Ansible).
  Per-host values (hostname, static IP) for multi-host role groups
  belong in `host_vars/<host>.yml`.
- `inventory` — `[init]` for fresh VMs plus `[docker]`, `[gpu]`,
  `[jellyfin]`, `[pterodactyl]`, `[nixos_wings]` role groups. Hosts
  move from `[init]` to a role group once their static IP is live.
  Group names use underscores, not hyphens — ansible otherwise warns
  "Invalid characters were found in group names" on every run.
- `scripts/server-bootstrap.sh` — one-time root-side prep run on a
  Debian target before Ansible takes over (creates the admin user +
  SSH key). `scripts/nixos-bootstrap.sh` is the NixOS equivalent.

## Host lifecycle

1. Install Debian 13 on the VM, run `server-bootstrap.sh` as root.
2. Add the host's DHCP IP under `[init]` in `inventory`. Edit
   `group_vars/init.yml` to set hostname + intended static IP.
3. `task deploy:all` — runs `setup-debian.yml` (full baseline).
4. Reboot the host so the static IP takes effect.
5. Move the host from `[init]` to its role group (`[docker]`,
   `[gpu]`, `[jellyfin]`, `[pterodactyl]`) in `inventory`, using its
   new static IP/FQDN.
6. `task deploy:<role>` — re-runs the full baseline against the role
   group and applies the role-specific phase. Safe to re-run anytime.

### NixOS hosts

The Wings nodes run NixOS, and the model differs enough to spell out.
There is no baseline chain: `nixos/modules/base.nix` *is* the baseline
(admin user + `public_keys/`, password-gated sudo, sshd with password
auth off, Docker with the same log rotation, timezone, unattended
upgrades), and it lands in the same switch as the role. Ansible is only
the transport — it syncs the flake and runs `nixos-rebuild`.

1. Install NixOS from the ISO on the VM, then run
   `scripts/nixos-bootstrap.sh -k "$(cat ~/.ssh/id_ed25519.pub)"` as
   root. It creates the admin user, enables sshd, and prints the
   machine's hardware config.
2. `cp -r nixos/hosts/wings1 nixos/hosts/<name>`, paste that hardware
   config over its `hardware.nix`, and set hostname, IP, interface and
   `stateVersion` in its `default.nix`. Add the host to
   `nixosConfigurations` in `nixos/flake.nix`.
3. Add its IP under `[nixos_wings]` in `inventory`, plus
   `host_vars/<ip>.yml` with `nixos_host: <name>`.
4. Put a sudo password hash in the vault as
   `nixos_admin_password_hash` — `task nixos:passwd` generates one,
   `task vault:edit` stores it. The flake references it by file path;
   the phase writes the file.
5. `task nix:check` — evaluates the flake and builds the Wings
   package, offline. The NixOS half's `task syntax` + Molecule; run it
   before deploying.
6. `task deploy:nixos-wings`.
7. Create the node in the panel, then on the host:
   `sudo wings configure --panel-url <panel url> --token <token>
   --node <id>` followed by `sudo systemctl start wings`.

## Portainer model

New VMs run the Portainer **Agent** (port 9001), not a standalone
Portainer server. The agent is managed by an external central
Portainer host added via the Portainer UI as an Environment. The
old `playbooks/debian-portainer.yml` (server) is kept for reference
but is not part of `setup-debian.yml`.

## Common Tasks

- `task` — list available tasks.
- `task init` — build the runner image and install collections (run
  once after clone or when `requirements.yml` changes).
- `task ping` — verify SSH + become to every host in `inventory`.
- `task test` — full playbook in `--check --diff` mode (no changes).
- `task deploy:all` — production deploy of `setup-debian.yml`
  (against `[init]`).
- `task deploy:docker` / `deploy:gpu` / `deploy:jellyfin` /
  `deploy:pterodactyl` — full role deploy (baseline + role phase)
  against the role group.
- `task deploy:gpu-only` / `deploy:jellyfin-only` /
  `deploy:pterodactyl-only` — re-run just the role-specific phase,
  skipping the baseline.
- `task deploy:nixos-wings` — converge the NixOS Wings hosts (sync
  the flake, then `nixos-rebuild switch`).
- `task nix:check` — evaluate the flake and build the Wings package,
  all offline. The gate before `deploy:nixos-wings`.
- `task nix:update` — bump `nixos/flake.lock`.
- `task nixos:passwd` — print a crypt hash for the vault.
- `task deploy:<phase>` — run a single baseline phase
  (`init`, `basic`, `network`, `docker`, `portainer-agent`,
  `cockpit`). Targets `[init]` by default; pass
  `CLI_ARGS='-e target_hosts=<group>'` to retarget.
- `task shell` — interactive bash inside the runner container.
- `task clean` / `task clean:all` — tear down runner state.

## Gotchas worth remembering

- The static IP set by `debian-network.yml` takes effect on next
  reboot. Until then, the host keeps its DHCP lease and may answer on
  both addresses.
- GPU hosts need a reboot after the first `deploy:gpu` run before the
  NVIDIA driver loads and `nvidia-smi` works. The Proxmox-level PCI
  passthrough is out of scope for this repo.
- Wings won't start until `/etc/pterodactyl/config.yml` exists — that
  file is generated by the panel when you create the node and pulled
  down with `wings configure`. The unit is gated on
  `ConditionPathExists`, so a converged-but-unconfigured node sits
  inert rather than crash-looping, and the phase prints the exact
  command to finish it.
- **NixOS hosts need `ansible_python_interpreter` set** (it's in
  `group_vars/nixos_wings.yml`). There is no `/usr/bin/python3`;
  interpreters live in the Nix store behind
  `/run/current-system/sw/bin/python3`. When discovery comes up empty
  the error names neither Python nor NixOS — you get a bare "module
  failed" on the first task.
- `nixos/hosts/<name>/hardware.nix` is **per-machine** and the shipped
  one is a placeholder. Switching with the wrong disks builds fine and
  then doesn't boot, so the phase checks that every `/dev/disk/by-*`
  path the file names exists on the target before switching.
- NixOS hosts get **no** unattended upgrades, unlike the Debian ones.
  `system.autoUpgrade` can't mean anything against a committed
  `flake.lock` — it either rebuilds the same pin nightly or drifts the
  host off the lock `nix:check` tested. Updates are explicit:
  `task nix:update && task nix:check && task deploy:nixos-wings`.
- Docker's `autoPrune` is off on Wings hosts: `docker system prune`
  deletes stopped containers, and a stopped container there is a game
  server someone turned off.
- Nix tasks address the flake as `path:./...`. Without the prefix nix
  notices the git work tree, resolves it as `git+file:///homelab`, and
  both fails on container-root-vs-host-uid ownership and would
  evaluate only *committed* files.
- Ansible's group names can't contain hyphens — `[nixos_wings]`, not
  `[nixos-wings]`, or every run warns "Invalid characters were found
  in group names". Task and file names still use hyphens.
- The Pterodactyl Panel's `APP_URL` must include its port, or Laravel
  serves asset URLs on port 80 and bounces every login. The
  `pterodactyl` Molecule scenario asserts this.
- `{{ pterodactyl_data_dir }}/var/` is the one directory you cannot
  lose. The panel image generates `APP_KEY` and `HASHIDS_SALT` on
  first boot into `var/.env` and reuses them forever; without that
  file every encrypted value in the database — node tokens, 2FA
  secrets — is undecryptable even from a good DB dump.
- Molecule generates its own `ansible.cfg`, so nothing from the repo's
  carries over — including `vault_password_file`. Each scenario sets
  it in `config_options.defaults`; without it every molecule action
  dies at "Attempting to decrypt but no vault secrets found", because
  the scenarios link the real `group_vars/` and it contains the
  encrypted vault.
- Jellyfin serves media from `jellyfin_media_dir` (`/srv/media`),
  mounted read-only into the container. With `jellyfin_media_nfs:
  true` the role deploy mounts `jellyfin_nfs_src` there (fstab-
  persistent) — the deploy refuses the shipped CHANGEME placeholder,
  so set the real export first. With `jellyfin_enable_gpu: true` the
  role deploy also runs the NVIDIA phase, which needs a reboot after
  its first run.
- Syncthing (part of the jellyfin role) mounts the media dir
  read-write; folder + device pairing is done in its GUI (:8384)
  out-of-band. On an NFS-backed library, disable "Watch for Changes"
  on the folder — inotify doesn't propagate over NFS — and rely on
  periodic rescans.
