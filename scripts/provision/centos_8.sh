#!/bin/bash
set -xe

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
service firezone start || true
systemctl status firezone.service
journalctl -u firezone
