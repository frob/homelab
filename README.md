# homelab

Ansible playbooks that take a freshly installed Debian 13 (Trixie) server
from bare-OS to a usable homelab host and then specialize it into a role:
plain Docker host, GPU/LLM host (NVIDIA driver + nvidia-container-toolkit),
Jellyfin media host, or Pterodactyl Panel host. Every Debian host gets the
same hardened baseline —
admin user with SSH key, static IP, hostname, unattended-upgrades,
firewall, Docker, Portainer Agent, and Cockpit — and then the role layer
on top.

The Pterodactyl **Wings** nodes are the exception: they run **NixOS**, and
their whole configuration is the flake under [`nixos/`](nixos/). Ansible is
only the transport there — it syncs the flake and runs `nixos-rebuild`.
Adding a game-server node is a host directory plus an inventory line, which
is the point: see [NixOS Wings hosts](#nixos-wings-hosts).

Everything runs inside a containerized Ansible runner — the only tools
required on your workstation are **Docker** and **[go-task]**. No Python,
no Ansible, no collections installed on the host.

[go-task]: https://taskfile.dev

---

## Prepare the target server (one-time, manual)

The Debian 13 netinst / minimal installer doesn't include `sudo` by
default and may not create your admin user with the right group
membership. The `scripts/server-bootstrap.sh` script does the whole
manual prep in one shot — copy it to the box and run it as root.

### Easy mode — run the bootstrap script

From your **workstation** (assuming SSH is already installed on the
server and you know the root password):

```sh
scp scripts/server-bootstrap.sh root@<server-ip>:/tmp/
ssh root@<server-ip> bash /tmp/server-bootstrap.sh -u frob \
    -k "$(cat ~/.ssh/id_rsa.pub)"
```

That single invocation will:

1. `apt update` + install `sudo`, `openssh-server`, `ca-certificates`, `curl`
2. Create the admin user (defaults to `frob`, override with `-u`)
3. Add the admin user to the `sudo` group
4. Drop your SSH public key into `~frob/.ssh/authorized_keys` (when `-k` is given)
5. Enable & start `ssh`
6. Print the server's primary interface + IP so you know what to put in `inventory` and `group_vars/init.yml`

If you can't `ssh root@…` directly (Debian disables root SSH by
default), log in at the **console** as your install user, `su -` to
root, then either re-type the script's commands by hand or transfer the
file via a USB stick / `scp` from a regular user first.

### Manual equivalent

```sh
# On the server console, as root (su -):
apt update
apt install -y sudo openssh-server
adduser frob              # skip if user already exists
usermod -aG sudo frob
systemctl enable --now ssh
ip -br a                  # note the IP + interface name
```

From your **workstation**, confirm you can reach the box with a
password before going further:

```sh
ssh frob@192.168.1.143       # should prompt for password and let you in
ssh frob@192.168.1.143 sudo -n true   # will fail; that's fine, just confirms sudo exists
```

Recommended: drop your SSH public key onto the server now so you won't
need passwords during the run:

```sh
ssh-copy-id frob@192.168.1.143
```

> If your admin user is **not** `frob`, edit `admin_user:` in
> `group_vars/init.yml` and `remote_user = frob` in `ansible.cfg` to
> match the account you actually created.

---

## Host lifecycle

Hosts move through two stages: a one-time **bootstrap** in the `[init]`
group, then ongoing management in a **role group** (`[docker]`, `[gpu]`,
`[jellyfin]`, `[pterodactyl]`). The NixOS Wings hosts (`[nixos_wings]`)
follow a different path — see [NixOS Wings hosts](#nixos-wings-hosts).

1. Fresh Debian VM → put its DHCP IP under `[init]` in `inventory`, edit
   `group_vars/init.yml` with the host's intended hostname + static IP.
2. `task deploy:all` — runs `setup-debian.yml` (full baseline).
3. Reboot — static IP takes effect.
4. Move the host from `[init]` into its role group in `inventory`, using
   the new static IP/FQDN. Add per-host vars in `host_vars/<host>.yml`
   if needed.
5. `task deploy:<role>` — re-runs the full baseline against the role
   group and applies the role-specific phase. Safe to re-run anytime.

## NixOS Wings hosts

The Pterodactyl **Panel** is an ordinary Debian role (`deploy:pterodactyl`
— baseline, then a compose stack of panel + MariaDB + Redis). The **Wings**
nodes that actually run game servers are NixOS, because that's the part
that multiplies: each new game host is the same machine with a different
name, IP and port range, so it should cost a file rather than a deploy to
babysit.

`nixpkgs` ships no Pterodactyl anything — there's no `pterodactyl-wings` in
`pkgs/by-name` and no `services.pterodactyl.*` in `module-list.nix` on 25.05
or unstable — so `nixos/pkgs/wings.nix` and `nixos/modules/wings.nix` are
ours. Wings ships a statically linked Go binary, so the package is a
`fetchurl` and an `install`, not a build.

**Ansible is only the transport.** `playbooks/nixos-wings.yml` syncs
`nixos/` (plus `public_keys/`) to `/etc/nixos`, writes the vaulted sudo
hash to `/etc/nixos-secrets/admin.pass`, and runs `nixos-rebuild switch
--flake /etc/nixos#<host>`. There is no baseline chain — apt, ifupdown,
ufw and hostnamectl mean nothing here, and `nixos/modules/base.nix` *is*
the baseline (admin user + `public_keys/`, password-gated sudo, sshd with
password auth off, Docker with the same log rotation, timezone, unattended
upgrades). It lands in the same switch as the role.

The one secret the flake needs is the admin's sudo password hash, and a
public repo can't hold it. `base.nix` sets
`users.users.<admin>.hashedPasswordFile = "/etc/nixos-secrets/admin.pass"`
— a path, not a literal — and the phase writes that file from
`nixos_admin_password_hash` in the vault. That file path is the seam
between a public Nix tree and a private credential.

### Adding a node

```sh
# 1. Install NixOS from the ISO on the VM, then as root on the box:
bash nixos-bootstrap.sh -k "$(cat ~/.ssh/id_ed25519.pub)"
#    It creates the admin user, enables sshd, and prints the machine's
#    hardware config.

# 2. In the repo:
cp -r nixos/hosts/wings1 nixos/hosts/wings2
#    Paste that hardware config over nixos/hosts/wings2/hardware.nix —
#    the shipped one is a placeholder. Set hostname, IP, interface,
#    stateVersion and the port ranges in default.nix, then add wings2 to
#    nixosConfigurations in nixos/flake.nix.

# 3. Inventory: add the IP under [nixos_wings], plus
#    host_vars/<ip>.yml containing `nixos_host: wings2`.

# 4. Sudo password hash into the vault (once, not per node):
task nixos:passwd          # prints a hash
task vault:edit            # store it as nixos_admin_password_hash

# 5. Check, then deploy.
task nix:check             # evaluates the flake AND builds the wings package
task deploy:nixos-wings

# 6. Create the node in the panel, then on the host:
sudo wings configure --panel-url http://util1.andrsn.org:8081 \
    --token <token from the panel> --node <node id>
sudo systemctl start wings
```

`task nix:check` is the gate, and it does more than evaluate: `nix flake
check` never builds, so a wrong hash in `pkgs/wings.nix` would sail past it
and fail on the host mid-deploy. The task builds the package too.

### Game server ports

`homelab.wings.gamePortRanges` in the host's `default.nix` opens the ports
the game servers themselves listen on, TCP and UDP. This is the thing you
hit first and the thing Wings has no opinion about: the panel will happily
allocate a server port 27015, and it's simply unreachable until that port
falls inside a range here. Keep it aligned with the allocations you create
for the node in the panel.

---

## Quickstart (from your workstation)

```sh
# 1. Edit your settings (host IP, hostname, network, etc.)
$EDITOR group_vars/init.yml
$EDITOR inventory

# 2. Make sure the SSH key you want pushed to the server is at:
#    ~/.ssh/id_rsa     (private — used by the runner to connect)
#    public_keys/id_rsa.pub  (public — installed into the admin user)

# 3. Bootstrap (build runner container + install collections)
task init

# 4. Verify connectivity
task ping

# 5. Dry-run — shows what WOULD change without changing anything
task test

# 6. Bootstrap deploy — runs setup-debian.yml against [init]
task deploy:all

# 7. Reboot the host so the static IP takes effect, then move it from
#    [init] to its role group in inventory ([docker], [gpu], [jellyfin],
#    or [pterodactyl]).

# 8. Role deploy — re-runs the baseline plus the role-specific phase.
task deploy:docker        # or deploy:gpu / deploy:jellyfin / deploy:pterodactyl
```

If `task ping` fails with "Missing sudo password" or "sudo: command not
found", revisit the **Prepare the target server** steps above — those
have to be done by hand on the box, the playbooks can't bootstrap
themselves without sudo.

If you skipped `ssh-copy-id`, the first run needs password auth:

```sh
task shell
# inside the runner container:
ansible-playbook -i inventory setup-debian.yml --ask-pass --ask-become-pass
```

Run `task` with no arguments to see every available command and what it
does:

```sh
$ task
* default:                  (prints this list)
* init:                     One-time bootstrap…
* build:container:          Build the ansible runner Docker image…
* lint:                     Run ansible-lint…
* check:                    Syntax-check every imported playbook…
* test:                     Dry-run the full playbook…
* ping:                     Verify SSH connectivity…
* facts:                    Gather and print Ansible facts…
* shell:                    Open an interactive bash shell…
* deploy:all:               Bootstrap deploy of setup-debian.yml against [init]…
* deploy:init:              Run only the APT init phase…
* deploy:basic:             Run only the basic-setup phase…
* deploy:network:           Run only the static-IP phase…
* deploy:docker:            Full role deploy against [docker]…
* deploy:gpu:               Full role deploy against [gpu]…
* deploy:gpu-only:          Just the NVIDIA phase against [gpu]…
* deploy:pterodactyl:       Full role deploy against [pterodactyl]…
* deploy:pterodactyl-only:  Just the Panel phase against [pterodactyl]…
* deploy:nixos-wings:       Converge the NixOS Wings hosts [nixos_wings]…
* nix:check:                Evaluate the NixOS flake + build wings…
* nix:update:               Bump nixos/flake.lock…
* nixos:passwd:             Print a crypt hash for the vault…
* deploy:jellyfin:          Full role deploy against [jellyfin]…
* deploy:jellyfin-only:     Just the Jellyfin phase against [jellyfin]…
* deploy:portainer-agent:   Run only the Portainer Agent phase…
* deploy:cockpit:           Run only the Cockpit phase…
* clean:                    Stop and remove the ansible runner container…
* clean:all:                …and delete the image and ./collections…
```

---

## What gets hardened

After `deploy:all` runs, the following lockdown is in place. **Make sure
your admin user works and has sudo BEFORE running it** — once it
completes, root is unreachable except through `sudo` from the admin
account, and only the admin user is allowed to SSH in.

**SSH:**
- `PasswordAuthentication no` — keys only
- `KbdInteractiveAuthentication no` — blocks PAM password fallback
- `PermitRootLogin no` — root cannot SSH in at all
- `AllowUsers <admin_user>` — only the admin user can log in; everyone else is rejected pre-auth
- `MaxAuthTries 3` + `LoginGraceTime 20` — tight per-connection brute-force window

**Root account:**
- Password set to a random 64-char value (never recorded anywhere) and then **locked** (`!` prefix in `/etc/shadow`). Sudo still works because it authenticates the calling user, not root.
- Recovery: in single-user / rescue mode run `passwd -u root && passwd root`.

**Firewall (ufw):**
- Default-deny inbound
- `limit OpenSSH` — kernel rate-limits SSH to ~6 new conns / 30s per source IP
- `allow 9090/tcp` (Cockpit), `allow 9001/tcp` (Portainer Agent)
- Role phases add their own rules:
  - `gpu` — none beyond baseline.
  - `pterodactyl` — `allow 8081/tcp` (Panel web UI + API).

  The NixOS Wings hosts don't use ufw at all; `networking.firewall` in
  `nixos/modules/wings.nix` opens 8080/tcp (panel→wings API), 2022/tcp
  (SFTP) and the configured game-server port ranges.
  - `jellyfin` — `allow 8096/tcp` (web UI), `allow 7359/udp` (client discovery), plus Syncthing: `allow 8384/tcp` (GUI), `allow 22000/tcp+udp` (sync), `allow 21027/udp` (local discovery).

**fail2ban:**
- `sshd` jail enabled (systemd journal backend)
- 3 failures in 10 min → 1-hour ban
- View status: `sudo fail2ban-client status sshd`

**Kernel (sysctl):**
- Source-route validation (`rp_filter=1`)
- Reject ICMP redirects (v4 + v6)
- Reject source-routed packets (v4 + v6)
- Log martian packets
- Ignore broadcast ICMP (smurf protection)
- SYN cookies + `tcp_rfc1337=1` (time-wait assassination)

To get a root shell after deploy: `sudo -i` from the admin account.

### Known caveats (not addressed)

- Members of the `docker` group can trivially escalate to root via
  `docker run -v /:/host …`. The admin user is in `docker`. Acceptable
  for a single-admin homelab; don't add untrusted users to the group.
- Portainer and Cockpit are reachable over the LAN with their own
  credentials. They are effectively root-equivalent if compromised. If
  this matters, put them behind a reverse proxy with mTLS or bind them
  to a VPN-only interface.

---

## Repo layout

```
.
├── Taskfile.yml                  # Single user-facing interface — run `task`
├── Dockerfile                    # debian:trixie + ansible + sshpass
├── docker-compose.yml            # Wraps the runner; mounts ~/.ssh/id_rsa as secret
├── ansible.cfg                   # Points at ./inventory, become_user=frob
├── inventory                     # [init] for fresh VMs + [docker]/[gpu]/[jellyfin]/[pterodactyl]/[nixos_wings] role groups
├── requirements.yml              # ansible-galaxy collections needed
├── group_vars/
│   ├── all.yml                   # Defaults shared by every group
│   ├── init.yml                  # Bootstrap identity + static IP for the [init] host
│   ├── docker.yml                # Plain-docker role overrides
│   ├── gpu.yml                   # GPU role — driver pkg, default runtime
│   ├── pterodactyl.yml           # Panel role — images, data dir, port, APP_URL
│   ├── nixos_wings.yml           # NixOS hosts — python interpreter (the flake owns the rest)
│   └── jellyfin.yml              # Jellyfin role — image, media dir, ports, GPU flag
├── public_keys/
│   └── id_rsa.pub                # Pushed to the admin user's authorized_keys
├── setup-debian.yml              # Bootstrap playbook — targets [init]
├── setup-docker.yml              # Role wrapper — baseline against [docker]
├── setup-gpu.yml                 # Role wrapper — baseline + GPU phase against [gpu]
├── setup-jellyfin.yml            # Role wrapper — baseline (+ optional GPU) + Jellyfin against [jellyfin]
├── setup-pterodactyl.yml         # Role wrapper — baseline + Panel phase against [pterodactyl]
├── setup-nixos-wings.yml         # NixOS Wings — the one phase, no baseline chain (base.nix is the baseline)
├── nixos/                        # The NixOS flake — see "NixOS Wings hosts"
│   ├── flake.nix                 # One nixosConfigurations entry per Wings node
│   ├── flake.lock                # Pinned nixpkgs — committed
│   ├── modules/base.nix          # Declarative baseline: user, keys, sudo, sshd, docker
│   ├── modules/wings.nix         # The wings service, firewall, tmpfiles
│   ├── pkgs/wings.nix            # The wings package (nixpkgs has none)
│   └── hosts/<name>/             # default.nix (identity, ports) + hardware.nix (per-machine)
└── playbooks/
    ├── debian-init.yml           # APT sources, dist-upgrade
    ├── debian-basic.yml          # Hostname, user, SSH, unattended-upgrades, ufw
    ├── debian-network.yml        # Static IP via ifupdown
    ├── debian-docker.yml         # Docker CE + daemon.json (log rotation, data-root)
    ├── debian-portainer-agent.yml # Portainer Agent on 9001
    ├── debian-cockpit.yml        # Cockpit on 9090
    ├── debian-gpu.yml            # NVIDIA driver + nvidia-container-toolkit
    ├── debian-wings.yml          # Pterodactyl Wings binary + systemd unit
    ├── debian-jellyfin.yml       # Jellyfin container (frob/cuddlefish) via compose
    ├── debian-nfs-media.yml      # NFS mount for the media library (fstab-persistent)
    ├── debian-syncthing.yml      # Syncthing container — library sync/backup
    └── debian-portainer.yml      # (legacy — standalone Portainer server, not used)
```

Every phase playbook targets `hosts: "{{ target_hosts | default('init') }}"`,
so the same files are reused across role groups — `setup-debian.yml`
runs them against `[init]`, and each `setup-<role>.yml` wrapper passes
`-e target_hosts=<role>` via its Taskfile entry.

---

## Configuration

Tunables are split between `group_vars/all.yml` (defaults shared by every
group) and the per-group files. Edit **before** running anything
destructive.

### `group_vars/all.yml` — shared defaults

| Variable | Purpose |
|---|---|
| `admin_user` | Account created on the target, given sudo + docker, receives the SSH key |
| `timezone` | IANA tz name (e.g. `America/Los_Angeles`) |
| `domain_name` | FQDN suffix used in `/etc/hosts` and banners |
| `sshd_PasswordAuthentication` | `"no"` to disable password SSH after the key is in place |
| `docker_data_root` | Where Docker stores images/volumes (defaults to `/var/lib/docker`) |
| `docker_log_max_size`, `docker_log_max_file` | json-file driver log rotation |
| `portainer_agent_image`, `portainer_agent_compose_dir`, `portainer_agent_port` | Portainer Agent config |

### `group_vars/init.yml` — bootstrap identity (per-VM)

| Variable | Purpose |
|---|---|
| `host_name` | Sets `/etc/hostname` and the FQDN in `/etc/hosts` |
| `network_interface` | NIC to apply the static IP to (`enp1s0`, `ens18`, etc.) — **see warning below** |
| `network_address`, `network_netmask`, `network_cidr` | Static IPv4 |
| `network_gateway`, `network_dns` | Default route + resolvers |

Because `[init]` is one-host-at-a-time, these live in group_vars and are
edited before each new-host run. For role groups holding multiple hosts,
put per-host values in `host_vars/<host>.yml`.

### `group_vars/gpu.yml` — GPU role

| Variable | Purpose |
|---|---|
| `nvidia_driver_package` | Driver package name (`nvidia-driver` for consumer cards; `nvidia-tesla-driver` for datacenter cards) |
| `nvidia_default_runtime` | If true, makes `nvidia` the default Docker runtime so containers see the GPU without opt-in |

### `group_vars/pterodactyl.yml` — Panel role

| Variable | Purpose |
|---|---|
| `pterodactyl_panel_image`, `pterodactyl_db_image`, `pterodactyl_cache_image` | Pinned images for the panel, MariaDB and Redis |
| `pterodactyl_compose_dir` | Where the compose file lives (default `/opt/pterodactyl`) |
| `pterodactyl_data_dir` | Stack state — DB, the panel's `var/` and logs. Override in `host_vars` to put it on a bigger volume |
| `pterodactyl_http_port` | Panel web UI + API (default `8081`) — opened in ufw |
| `pterodactyl_app_url` | **Must include the port.** Laravel builds every asset and redirect URL from it |
| `pterodactyl_db_name`, `pterodactyl_db_user` | Database the panel owns |

The two passwords are **not** here — `pterodactyl_db_password` and
`pterodactyl_db_root_password` live in `group_vars/all/vault.yml`
(`task vault:edit`), because this repo is public. The phase asserts both
are set before it renders anything.

### NixOS Wings role

There is no `group_vars` table for Wings: the NixOS hosts are configured
by the flake, not by Ansible variables. The knobs are
`homelab.wings.{apiPort,sftpPort,gamePortRanges,dataDir}` in
`nixos/hosts/<name>/default.nix`. See
[NixOS Wings hosts](#nixos-wings-hosts).

### `group_vars/jellyfin.yml` — Jellyfin role

| Variable | Purpose |
|---|---|
| `jellyfin_image` | Container image, pinned to a release tag (e.g. `frob/cuddlefish:10.11.11`) |
| `jellyfin_compose_dir` | Where the compose file lives on the host (default `/opt/jellyfin`) |
| `jellyfin_config_dir`, `jellyfin_cache_dir` | Bind mounts for Jellyfin's `/config` and `/cache` |
| `jellyfin_media_dir` | Host media directory, mounted read-only at `/media` (default `/srv/media`) |
| `jellyfin_http_port` | Web UI/API (default `8096`) — opened in ufw |
| `jellyfin_discovery_port` | LAN client auto-discovery (default `7359/udp`) — opened in ufw |
| `jellyfin_enable_gpu` | If true, the role deploy also runs the NVIDIA phase and the container gets the `nvidia` runtime for hardware transcoding (set the `nvidia_*` vars too; reboot after first run) |
| `jellyfin_media_nfs` | If true, the role deploy mounts an NFS export at `jellyfin_media_dir` before the containers start |
| `jellyfin_nfs_src`, `jellyfin_nfs_opts` | NFS export (`server:/path`) and mount options — the deploy refuses the shipped `CHANGEME` placeholder |
| `syncthing_image` | Syncthing container image, pinned (e.g. `syncthing/syncthing:2.1.2`) |
| `syncthing_gui_port`, `syncthing_sync_port`, `syncthing_discovery_port` | GUI (`8384`), sync (`22000` tcp+udp), local discovery (`21027/udp`) — all opened in ufw |
| `syncthing_uid`, `syncthing_gid` | Account Syncthing runs as — must be able to write the NFS export |

### Inventory

The inventory has one bootstrap group plus a group per role:

```ini
[init]
192.168.1.143

[docker]
# util1.andrsn.org

[gpu]
# llm1.andrsn.org

[nixos_wings]
# 192.168.1.60   # wings1 — NixOS; nixos_host in host_vars/192.168.1.60.yml

[pterodactyl]
# 192.168.1.50

[jellyfin]
# media1.andrsn.org
```

`[init]` is for fresh VMs still on a DHCP lease. Once the static IP is
live, move the host out of `[init]` and into its role group, addressed
by the new IP or FQDN. Role playbooks re-run the full baseline (so the
host stays in sync with `all.yml` changes too) before applying the role
phase — every phase is idempotent.

### SSH keys

The runner container mounts `~/.ssh/id_rsa` from your workstation as a
Docker secret and uses it to log in to the target. The key that gets
**installed on the target host's admin user** is read from
[`public_keys/id_rsa.pub`](public_keys/id_rsa.pub) — replace that file
with the public key you want authorized.

---

## Testing & verification workflow

The recommended progression — each step is safe to repeat:

```sh
task lint              # static analysis (no network)
task syntax            # syntax-check all playbooks (no network)
task molecule:test:all # converge every role phase in throwaway containers
task nix:check         # evaluate the NixOS flake + build the wings package
task ping              # SSH + sudo connectivity to every host
task facts             # full ansible facts dump — confirms real NIC name etc.
task test              # full --check --diff dry-run (connects but changes nothing)
task deploy:all        # the real thing
```

`task molecule:test:all` runs three scenarios: `default` (the
container-safe baseline phases), `jellyfin` and `pterodactyl`. The two
role scenarios exist because those phases render compose files as Jinja
heredocs — they slurp the result back and **parse** it, so a template typo
fails there instead of leaving a stack down on a live host. The NixOS half
isn't covered by Molecule; `task nix:check` is its equivalent.

If you only want to test one piece, every playbook has its own
`deploy:<name>` task — e.g. `task deploy:cockpit` runs only the Cockpit
playbook. All deploy tasks also accept `--check` style flags via the
underlying playbook; for a one-off dry-run of a single piece, use
`task shell` and invoke `ansible-playbook` directly inside the container.

### First-host gotchas

1. **Network interface name.** Cloud / minimal Debian 13 installs almost
   never name the primary NIC `eth0` — it's typically `enp1s0`, `ens18`,
   `ens33`, or similar. Run `task facts` first and look at
   `ansible_default_ipv4.interface` before running `task deploy:network`.
   A wrong value will **lock you out of SSH** on next boot. Have console
   access ready.

2. **Initial connection uses password auth.** On a fresh box the runner
   needs to ssh in with a password to drop the key. Either configure
   ansible to prompt (`task shell` then
   `ansible-playbook ... -k -K`), or get the key onto the host out of
   band first (`ssh-copy-id`).

3. **Service ports.** Once deployed:
   - Cockpit:         `https://<host>:9090` (self-signed cert)
   - Portainer Agent: `<host>:9001` — no web UI; add it to your central
     Portainer server under *Environments → Add environment → Agent*.

4. **GPU hosts need a reboot** after the first `deploy:gpu` run before
   the NVIDIA driver loads and `nvidia-smi` works. Proxmox-level PCI
   passthrough is out of scope for this repo.

5. **Wings won't start until `/etc/pterodactyl/config.yml` exists** on
   the node — it's generated by the panel when you create the node and
   pulled down with `wings configure`. The unit is gated on
   `ConditionPathExists`, so an unconfigured node sits inert instead of
   crash-looping, and `deploy:nixos-wings` prints the command to finish
   it.

6. **The Panel's `var/` directory is irreplaceable.** The panel image
   generates `APP_KEY` and `HASHIDS_SALT` on first boot and persists them
   to `{{ pterodactyl_data_dir }}/var/.env`. Lose that file and every
   encrypted value in the database — node tokens, user 2FA secrets — is
   unrecoverable even from a good DB dump. Back it up with the database.

7. **`nixos/hosts/<name>/hardware.nix` is per-machine.** The shipped one
   is a placeholder; replace it with
   `nixos-generate-config --show-hardware-config` output from the real
   box. `deploy:nixos-wings` refuses to switch if the devices it names
   don't exist on the target, because a wrong one builds fine and then
   doesn't boot.

---

## Cleaning up

```sh
task clean       # stop & remove the ansible runner container
task clean:all   # also delete the built image and ./collections/
```

Neither touches the remote host — only your local Docker resources.

---

## Adding a new phase or role

**A new baseline phase** (something every host should get):

1. Create `playbooks/debian-<name>.yml` with
   `hosts: "{{ target_hosts | default('init') }}"`.
2. Import it from `setup-debian.yml` **and** from each
   `setup-<role>.yml` wrapper so role hosts pick it up too.
3. Add a `deploy:<name>` task to `Taskfile.yml`.
4. Put new tunables in `group_vars/all.yml`.

**A new role** (a new specialization layered on the baseline):

1. Create `playbooks/debian-<role>.yml` for the role-specific phase
   (same `target_hosts` default pattern).
2. Create `setup-<role>.yml` that imports the full baseline plus the
   new phase.
3. Add a `[<role>]` group to `inventory` and `group_vars/<role>.yml`
   for the role's tunables.
4. Add `deploy:<role>` (full deploy) and `deploy:<role>-only` (just the
   role phase) entries to `Taskfile.yml`.
5. `task lint && task check` before opening a PR.
