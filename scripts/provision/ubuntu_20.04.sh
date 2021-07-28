#!/bin/bash
set -x

apt-get install -y -q \
  net-tools \
  iptables \
  openssl \
  postgresql \
  systemd \
  wireguard-tools
systemctl enable postgresql
systemctl start postgresql

dpkg -i /tmp/firezone*.deb
systemctl start firezone || true
systemctl status firezone.service
journalctl -xeu firezone
