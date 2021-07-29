#!/bin/bash
set -x

export DEBIAN_FRONTEND=noninteractive

# Install prerequisites
apt-get install -y -q \
  net-tools \
  iptables \
  openssl \
  postgresql \
  systemd
systemctl enable postgresql
systemctl start postgresql

# Add Backports repo
echo "deb http://deb.debian.org/debian buster-backports main" > /etc/apt/sources.list.d/backports.list
apt-get -q update

# Install WireGuard
apt-get install -y -q \
  wireguard \
  wireguard-tools

file=(/tmp/firezone*.tar.gz)
/tmp/install.sh /tmp/$file





# systemctl start firezone || true
# systemctl status firezone.service
# journalctl -xeu firezone
