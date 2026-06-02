#!/usr/bin/env bash
# Run this on a freshly installed Debian 13 (Trixie) server, as root,
# to install everything the ansible playbooks need to take over.
#
# Usage (on the server):
#   su -                                       # become root
#   bash server-bootstrap.sh                   # uses defaults (user: frob)
#   bash server-bootstrap.sh -u myuser         # override admin user
#   bash server-bootstrap.sh -u frob -k "ssh-ed25519 AAAA…"   # also drop a key
#
# Or pipe it in directly from the workstation:
#   scp scripts/server-bootstrap.sh root@<ip>:/tmp/
#   ssh root@<ip> bash /tmp/server-bootstrap.sh

set -euo pipefail

ADMIN_USER="frob"
SSH_PUBKEY=""

usage() {
    cat <<EOF
Usage: $0 [-u admin_user] [-k "ssh-pubkey-string"]

  -u   Username to create with sudo + ssh access (default: frob).
       Must match \`admin_user\` in group_vars/init.yml.
  -k   Optional SSH public key to drop into ~/.ssh/authorized_keys.
       Skip the workstation \`ssh-copy-id\` step if you pass this.
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
    echo "ERROR: must run as root. Try: su -" >&2
    exit 1
fi

if ! grep -qi 'debian' /etc/os-release; then
    echo "WARN: /etc/os-release does not look like Debian. Continuing anyway." >&2
fi

echo "==> Updating apt cache"
apt-get update -y

echo "==> Installing sudo, openssh-server, ca-certificates, curl"
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    sudo \
    openssh-server \
    ca-certificates \
    curl

if id "$ADMIN_USER" &>/dev/null; then
    echo "==> User '$ADMIN_USER' already exists — skipping creation"
else
    echo "==> Creating user '$ADMIN_USER' (you'll be prompted for a password)"
    adduser --gecos "" "$ADMIN_USER"
fi

echo "==> Adding '$ADMIN_USER' to the sudo group"
usermod -aG sudo "$ADMIN_USER"

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
fi

echo "==> Enabling and starting ssh"
systemctl enable --now ssh

PRIMARY_IFACE="$(ip -o -4 route show to default | awk '{print $5}' | head -n1 || true)"
PRIMARY_IP="$(ip -o -4 addr show "${PRIMARY_IFACE}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"

echo
echo "================ Bootstrap complete ================"
echo " Admin user : $ADMIN_USER  (in 'sudo' group)"
echo " SSH        : enabled & running"
echo " Interface  : ${PRIMARY_IFACE:-<unknown>}"
echo " IP address : ${PRIMARY_IP:-<unknown>}"
echo
echo " Next steps from your workstation:"
echo "   1. Put '${PRIMARY_IP:-<server-ip>}' in ./inventory"
echo "   2. Set network_interface: ${PRIMARY_IFACE:-<iface>} in group_vars/init.yml"
echo "   3. (If you didn't pass -k) run: ssh-copy-id ${ADMIN_USER}@${PRIMARY_IP:-<server-ip>}"
echo "   4. task ping && task test && task deploy:all"
echo "===================================================="
