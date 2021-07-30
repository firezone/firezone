#!/bin/bash
set -x

# Install prerequisites
yum install -y \
  openssl \
  net-tools \
  systemd \
  postgresql-server \
  iptables
postgresql-setup initdb
# Fix postgres login
cat <<EOT > /var/lib/pgsql/data/pg_hba.conf
local   all             all                                     peer
host    all             all             127.0.0.1/32            md5
host    all             all             ::1/128                 md5
EOT
systemctl enable postgresql
systemctl restart postgresql

# Install WireGuard
yum install -y epel-release elrepo-release
yum install -y yum-plugin-elrepo
yum install -y kmod-wireguard wireguard-tools


file=(/tmp/firezone*.tar.gz)
/tmp/install.sh $file

# systemctl start firezone.service
# systemctl status firezone.service
# journalctl -xeu firezone
