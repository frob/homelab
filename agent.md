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

- `setup-debian.yml` — top-level playbook, imports every phase.
- `playbooks/debian-*.yml` — one playbook per phase (init, basic,
  network, docker, portainer-agent, cockpit). Each is independently
  runnable via its own `deploy:*` task.
- `group_vars/init.yml` — variables for the `init` host group.
  Everything in `setup-debian.yml` targets `hosts: init`.
- `inventory` — only the `[init]` group exists. New VMs go here.
- `scripts/server-bootstrap.sh` — one-time root-side prep run on the
  target before Ansible takes over (creates the admin user + SSH key).

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
- `task deploy:all` — production deploy of `setup-debian.yml`.
- `task deploy:<phase>` — run a single phase
  (`init`, `basic`, `network`, `docker`, `portainer-agent`,
  `cockpit`).
- `task shell` — interactive bash inside the runner container.
- `task clean` / `task clean:all` — tear down runner state.

## Gotchas worth remembering

- The static IP set by `debian-network.yml` takes effect on next
  reboot. Until then, the host keeps its DHCP lease and may answer on
  both addresses.
