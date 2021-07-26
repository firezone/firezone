#!/bin/bash
set -xe

apt-get install -y -q \
  net-tools \
  iptables \
  openssl \
  postgresql \
  systemd \
  wireguard-tools
service postgresql start

dpkg -i /tmp/firezone*.deb
systemctl start firezone || true
systemctl status firezone.service
journalctl -xeu firezone
