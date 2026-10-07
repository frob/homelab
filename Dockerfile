FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get -y update
RUN apt-get -y upgrade
RUN apt-get -y install \
    ansible \
    ansible-lint \
    cowsay \
    docker.io \
    # ansible-vault shells out to $EDITOR and falls back to `vi`;
    # debian:trixie ships no editor at all, so `task vault:edit` dies
    # with "No such file or directory: vi" without this.
    nano \
    python3-pip \
    python3-venv \
    sshpass

# Molecule + docker driver live in pip. --break-system-packages is fine
# here because this image is throwaway tooling, not a long-lived host.
RUN pip3 install --break-system-packages --no-cache-dir \
    "molecule" \
    "molecule-plugins[docker]" \
    "docker"

CMD ["ansible"]

RUN mkdir /ansible
WORKDIR /ansible

# Setup ssh secret keys & known_hosts. The link name is key-type
# neutral on purpose — the secret may be RSA or ed25519 depending on
# ANSIBLE_SSH_KEY. ansible.cfg's private_key_file points here.
RUN mkdir -p /root/.ssh
RUN ln -s /run/secrets/user_ssh_key /root/.ssh/id_ansible
