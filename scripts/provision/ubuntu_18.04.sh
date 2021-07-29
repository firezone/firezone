#!/bin/bash
set -x

export DEBIAN_FRONTEND=noninteractive

apt-get install -y -q \
  net-tools \
  iptables \
  openssl \
  postgresql \
  systemd \
  wireguard \
  wireguard-tools
systemctl enable postgresql
systemctl start postgresql

file=(/tmp/firezone*.tar.gz)
/tmp/install.sh /tmp/$file

# systemctl start firezone
# systemctl status firezone.service
# journalctl -xeu firezone
