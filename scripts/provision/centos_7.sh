#!/bin/bash
set -x

# Install prerequisites
yum -y install https://download.postgresql.org/pub/repos/yum/reporpms/EL-7-x86_64/pgdg-redhat-repo-latest.noarch.rpm
yum -y install epel-release yum-utils
yum-config-manager --enable pgdg12
yum -y install postgresql12-server postgresql12
/usr/pgsql-12/bin/postgresql-12-setup initdb
# Fix postgres login
cat <<EOT >> /var/lib/pgsql/12/data/pg_hba.conf
local   all             all                                     peer
host    all             all             127.0.0.1/32            md5
host    all             all             ::1/128                 md5
EOT
systemctl enable --now postgresql-12

yum install -y \
  openssl \
  net-tools \
  systemd \
  iptables

# Install WireGuard
yum install -y epel-release elrepo-release
yum install -y yum-plugin-elrepo
yum install -y kmod-wireguard wireguard-tools

rpm -ivh /tmp/firezone*.rpm
systemctl start firezone
systemctl status firezone.service
journalctl -xeu firezone
