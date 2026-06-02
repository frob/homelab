# homelab

Ansible playbooks that take a freshly installed Debian 13 (Trixie) server
from bare-OS to a usable homelab host: admin user with SSH key, static IP,
hostname, unattended-upgrades, firewall, Docker, Portainer, and Cockpit.

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

# 6. Deploy for real
task deploy:all
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
* default:               (prints this list)
* init:                  One-time bootstrap…
* build:container:       Build the ansible runner Docker image…
* lint:                  Run ansible-lint…
* check:                 Syntax-check every imported playbook…
* test:                  Dry-run the full playbook…
* ping:                  Verify SSH connectivity…
* facts:                 Gather and print Ansible facts…
* shell:                 Open an interactive bash shell…
* deploy:all:            Run the complete setup-debian.yml playbook…
* deploy:init:           Run only the APT init playbook…
* deploy:basic:          Run only the basic-setup playbook…
* deploy:network:        Run only the static-IP / ifupdown playbook…
* deploy:docker:         Run only the Docker install playbook…
* deploy:portainer:      Run only the Portainer playbook…
* deploy:cockpit:        Run only the Cockpit playbook…
* clean:                 Stop and remove the ansible runner container…
* clean:all:             …and delete the image and ./collections…
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
- `allow 9090/tcp` (Cockpit), `allow 9443/tcp` (Portainer)

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
├── Taskfile.yml             # Single user-facing interface — run `task`
├── Dockerfile               # debian:trixie + ansible + sshpass
├── docker-compose.yml       # Wraps the runner; mounts ~/.ssh/id_rsa as secret
├── ansible.cfg              # Points at ./inventory, become_user=frob
├── inventory                # Hosts under the [init] group — first-run only
├── requirements.yml         # ansible-galaxy collections needed
├── group_vars/
│   └── init.yml             # Tunables for the [init] group ONLY
│                            # (post-init management uses a separate inventory/group)
├── public_keys/
│   └── id_rsa.pub           # Pushed to the admin user's authorized_keys
├── setup-debian.yml         # Top-level playbook (imports everything below)
└── playbooks/
    ├── debian-init.yml      # APT sources, dist-upgrade
    ├── debian-basic.yml     # Hostname, user, SSH, unattended-upgrades, ufw
    ├── debian-network.yml   # Static IP via ifupdown
    ├── debian-docker.yml    # Docker CE + daemon.json (log rotation, data-root)
    ├── debian-portainer.yml # Portainer CE via docker compose
    └── debian-cockpit.yml   # Cockpit on 9090
```

---

## Configuration

Every tunable lives in [`group_vars/init.yml`](group_vars/init.yml). Edit
this **before** running anything destructive.

| Variable | Purpose |
|---|---|
| `admin_user` | Account created on the target, given sudo + docker, receives the SSH key |
| `timezone` | IANA tz name (e.g. `America/Los_Angeles`) |
| `host_name`, `domain_name` | Sets `/etc/hostname` and the FQDN in `/etc/hosts` |
| `network_interface` | NIC to apply the static IP to (e.g. `eth0`, `enp1s0`, `ens18`) — **see warning below** |
| `network_address`, `network_netmask`, `network_cidr` | Static IPv4 |
| `network_gateway`, `network_dns` | Default route + resolvers |
| `sshd_PasswordAuthentication` | `"no"` to disable password SSH after the key is in place |
| `docker_data_root` | Where Docker stores images/volumes (defaults to `/var/lib/docker`) |
| `docker_log_max_size`, `docker_log_max_file` | json-file driver log rotation |
| `portainer_*` | Portainer image, host paths, exposed port |

### Inventory

`./inventory` is intentionally **init-only**. Hosts live under the
`[init]` group, and every init playbook uses `hosts: init`:

```ini
[init]
192.168.1.143
```

`group_vars/init.yml` is loaded for any host in `[init]`, so adding a
second VM means adding another line here and running through the same
flow. After init, the host has a permanent static IP and shouldn't be
in the `[init]` group anymore — future management work will use a
separate inventory file / group name (not yet built).

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
task lint           # static analysis (no network)
task check          # syntax-check all playbooks (no network)
task ping           # SSH + sudo connectivity to every host
task facts          # full ansible facts dump — confirms real NIC name etc.
task test           # full --check --diff dry-run (connects but changes nothing)
task deploy:all     # the real thing
```

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

3. **Cockpit & Portainer ports.** Once deployed:
   - Portainer: `https://<host>:9443`
   - Cockpit:   `https://<host>:9090`

   Both use self-signed certs out of the box.

---

## Cleaning up

```sh
task clean       # stop & remove the ansible runner container
task clean:all   # also delete the built image and ./collections/
```

Neither touches the remote host — only your local Docker resources.

---

## Adding a new playbook

1. Create `playbooks/debian-<name>.yml`.
2. Add it to the import list in [`setup-debian.yml`](setup-debian.yml).
3. Add a matching `deploy:<name>` task to [`Taskfile.yml`](Taskfile.yml)
   modeled on the existing ones.
4. Add any new tunables to `group_vars/init.yml` rather than hardcoding
   them in the playbook.
5. `task lint && task check` before opening a PR.
