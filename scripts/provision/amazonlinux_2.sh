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
curl -L -o /etc/yum.repos.d/wireguard.repo https://copr.fedorainfracloud.org/coprs/jdoss/wireguard/repo/epel-7/jdoss-wireguard-epel-7.repo
yum install -y wireguard-dkms wireguard-tools

rpm -ivh /tmp/firezone*.rpm
service firezone start
