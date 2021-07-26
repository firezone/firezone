#!/bin/bash
set -xe

# Install prerequisites
apt-get install -y -q \
  net-tools \
  iptables \
  openssl \
  postgresql \
  systemd
service postgresql start

# Add Backports repo
echo "deb http://deb.debian.org/debian buster-backports main" > /etc/apt/sources.list.d/backports.list
apt-get -q update

# Install WireGuard
apt-get install wireguard-tools

dpkg -i /tmp/firezone*.deb
service firezone start || true
systemctl status firezone.service
journalctl -u firezone
