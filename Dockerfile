FROM debian:bookworm

ENV DEBAN_FRONTEND=noninteractive

RUN apt-get -y update
RUN apt-get -y upgrade
RUN apt-get -y install \
    ansible \
    cowsay \
    sshpass

CMD ["ansible"]

RUN mkdir /ansible
WORKDIR /ansible

# Setup ssh secret keys & known_hosts.
RUN mkdir -p /root/.ssh
RUN ln -s /run/secrets/user_ssh_key /root/.ssh/id_rsa
