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
service firezone start || true
systemctl status firezone.service
journalctl -u firezone
