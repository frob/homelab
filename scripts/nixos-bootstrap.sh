#!/usr/bin/env bash
# Run this on a freshly installed NixOS server, as root, to give the
# ansible playbooks a way in. The NixOS counterpart to
# server-bootstrap.sh.
#
# It does the bare minimum and nothing declarative: a NixOS box's real
# configuration comes from the flake under nixos/ on the next
# `task deploy:nixos-wings`. All this does is open the door — a user,
# a key, sshd, sudo — and print the two things you need to copy back
# into the repo.
#
# Usage (on the server):
#   sudo -i                                            # become root
#   bash nixos-bootstrap.sh -k "ssh-ed25519 AAAA…"     # recommended
#   bash nixos-bootstrap.sh -u myuser -k "ssh-…"       # override user
#
# Or pipe it in from the workstation:
#   scp scripts/nixos-bootstrap.sh root@<ip>:/tmp/
#   ssh root@<ip> bash /tmp/nixos-bootstrap.sh -k "$(cat ~/.ssh/id_ed25519.pub)"

set -euo pipefail

ADMIN_USER="frob"
SSH_PUBKEY=""

usage() {
    cat <<EOF
Usage: $0 [-u admin_user] [-k "ssh-pubkey-string"]

  -u   Username to create with wheel + ssh access (default: frob).
       Must match the user declared in nixos/modules/base.nix.
  -k   SSH public key to drop into ~/.ssh/authorized_keys. Strongly
       recommended: the flake turns password auth off on the first
       switch, so without a key you'd lock Ansible out.
  -h   Show this help.
EOF
}

while getopts ":u:k:h" opt; do
    case "$opt" in
        u) ADMIN_USER="$OPTARG" ;;
        k) SSH_PUBKEY="$OPTARG" ;;
        h) usage; exit 0 ;;
        \?) echo "Unknown option: -$OPTARG" >&2; usage; exit 2 ;;
        :)  echo "Option -$OPTARG requires an argument." >&2; exit 2 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must run as root. Try: sudo -i" >&2
    exit 1
fi

if [[ ! -e /etc/NIXOS ]]; then
    echo "ERROR: this is not a NixOS system (/etc/NIXOS missing)." >&2
    echo "       For Debian hosts use scripts/server-bootstrap.sh." >&2
    exit 1
fi

# On NixOS these are declarative, so this script can't install packages
# or enable units the way the Debian one does — it edits the stock
# /etc/nixos/configuration.nix just enough to get sshd and the user up,
# and that file is then replaced wholesale by the flake on the first
# deploy. Anything written here is temporary by design.
CONF=/etc/nixos/configuration.nix
STAMP="# --- added by nixos-bootstrap.sh (replaced by the homelab flake) ---"

if [[ ! -f "$CONF" ]]; then
    echo "ERROR: $CONF not found. Finish the NixOS installer first." >&2
    exit 1
fi

if grep -qF "$STAMP" "$CONF"; then
    echo "==> $CONF already bootstrapped — skipping edit"
else
    echo "==> Backing up $CONF to ${CONF}.pre-bootstrap"
    cp -n "$CONF" "${CONF}.pre-bootstrap"

    echo "==> Adding sshd + '$ADMIN_USER' to $CONF"
    # Insert before the final closing brace.
    python3 - "$CONF" "$STAMP" "$ADMIN_USER" <<'PY'
import sys
path, stamp, user = sys.argv[1], sys.argv[2], sys.argv[3]
block = f'''
{stamp}
  services.openssh.enable = true;
  services.openssh.settings.PermitRootLogin = "no";
  users.users.{user} = {{
    isNormalUser = true;
    extraGroups = [ "wheel" ];
  }};
  environment.systemPackages = [ pkgs.python3 pkgs.rsync ];
# --- end nixos-bootstrap.sh ---
'''
src = open(path).read()
idx = src.rstrip().rfind('}')
open(path, 'w').write(src[:idx] + block + src[idx:])
PY
fi

echo "==> Applying the temporary configuration (nixos-rebuild switch)"
nixos-rebuild switch

echo "==> Setting a password for '$ADMIN_USER' (needed for sudo)"
echo "    The flake sets this declaratively later from the vault; this"
echo "    one just gets you through the first deploy."
passwd "$ADMIN_USER"

if [[ -n "$SSH_PUBKEY" ]]; then
    SSH_DIR="/home/${ADMIN_USER}/.ssh"
    AUTH_KEYS="${SSH_DIR}/authorized_keys"
    echo "==> Installing SSH public key into ${AUTH_KEYS}"
    install -d -m 0700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$SSH_DIR"
    touch "$AUTH_KEYS"
    if ! grep -qxF "$SSH_PUBKEY" "$AUTH_KEYS"; then
        echo "$SSH_PUBKEY" >> "$AUTH_KEYS"
    fi
    chown "$ADMIN_USER:$ADMIN_USER" "$AUTH_KEYS"
    chmod 0600 "$AUTH_KEYS"
else
    echo "WARN: no -k key given. Run ssh-copy-id from your workstation" >&2
    echo "      before deploying — the flake disables password auth." >&2
fi

PRIMARY_IFACE="$(ip -o -4 route show to default | awk '{print $5}' | head -n1 || true)"
PRIMARY_IP="$(ip -o -4 addr show "${PRIMARY_IFACE}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
STATE_VERSION="$(nixos-version | cut -d. -f1,2 || true)"

echo
echo "================ Bootstrap complete ================"
echo " Admin user    : $ADMIN_USER  (in 'wheel' group)"
echo " SSH           : enabled & running"
echo " Interface     : ${PRIMARY_IFACE:-<unknown>}"
echo " IP address    : ${PRIMARY_IP:-<unknown>}"
echo " stateVersion  : ${STATE_VERSION:-<unknown>}"
echo
echo " Next, in the repo on your workstation:"
echo "   1. cp -r nixos/hosts/wings1 nixos/hosts/<name>   (for a new node)"
echo "   2. Paste the hardware config printed below over"
echo "      nixos/hosts/<name>/hardware.nix — the shipped one is a"
echo "      placeholder, and the deploy refuses to switch until the"
echo "      devices it names exist on this host."
echo "   3. Set hostname, IP (${PRIMARY_IP:-<ip>}), interface"
echo "      (${PRIMARY_IFACE:-<iface>}) and stateVersion"
echo "      (${STATE_VERSION:-<ver>}) in nixos/hosts/<name>/default.nix,"
echo "      and add it to nixosConfigurations in nixos/flake.nix."
echo "   4. Add '${PRIMARY_IP:-<ip>}' under [nixos-wings] in ./inventory,"
echo "      and host_vars/${PRIMARY_IP:-<ip>}.yml with nixos_host: <name>."
echo "   5. task nix:check && task ping && task deploy:nixos-wings"
echo "===================================================="
echo
echo "---------------- hardware config -------------------"
nixos-generate-config --show-hardware-config
echo "----------------------------------------------------"
