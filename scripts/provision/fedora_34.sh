#!/bin/bash
set -x

# Install prerequisites
yum install -y \
  openssl \
  net-tools \
  postgresql-server \
  systemd \
  iptables \
  wireguard-tools
postgresql-setup --initdb --unit postgresql
systemctl restart postgresql

rpm -ivh /tmp/firezone*.rpm
systemctl start firezone
systemctl status firezone.service
journalctl -xeu firezone
