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

which wg
