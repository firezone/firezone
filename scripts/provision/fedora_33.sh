#!/bin/bash
set -xe

# Install prerequisites
yum install -y \
  openssl \
  net-tools \
  postgresql-server \
  systemd \
  iptables \
  wireguard-tools
postgresql-setup initdb
systemctl restart postgresql

rpm -ivh /tmp/firezone*.rpm
service firezone start
