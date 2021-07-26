#!/bin/bash
set -x

# Install prerequisites
yum install -y \
  openssl \
  net-tools \
  postgresql-server \
  systemd \
  iptables
postgresql-setup initdb
systemctl restart postgresql

# Install WireGuard
yum install -y epel-release elrepo-release
yum install -y kmod-wireguard wireguard-tools

rpm -ivh /tmp/firezone*.rpm
systemctl start firezone || true
systemctl status firezone.service
journalctl -xeu firezone
