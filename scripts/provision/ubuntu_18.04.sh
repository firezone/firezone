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

dpkg -i /tmp/firezone*.deb
systemctl start firezone
systemctl status firezone.service
journalctl -xeu firezone
