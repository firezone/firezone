#!/bin/bash
set -xe

yum install -y \
  openssl \
  net-tools \
  postgresql-server \
  systemd \
  iptables

postgresql-setup initdb
systemctl restart postgresql
