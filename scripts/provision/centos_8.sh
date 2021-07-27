#!/bin/bash
set -x

# Install prerequisites
yum install -y \
  openssl \
  net-tools \
  postgresql-server \
  systemd \
  iptables
postgresql-setup --initdb --unit postgresql
# Fix postgres login
cat <<EOT > /var/lib/pgsql/data/pg_hba.conf
local   all             all                                     peer
host    all             all             127.0.0.1/32            md5
host    all             all             ::1/128                 md5
EOT
systemctl restart postgresql

# Install WireGuard
yum install -y epel-release elrepo-release
yum install -y kmod-wireguard wireguard-tools

rpm -ivh /tmp/firezone*.rpm

echo "sourcing secrets file"
set -o allexport; source /etc/firezone/secret/secrets.env; set +o allexport

echo "DB USER: ${DB_USER}"
echo "DB PASS: ${DB_PASSWORD}"

PG_PASSWORD=$DB_PASSWORD PGUSER=$DB_USER psql -U $DB_USER -h 127.0.0.1 -d firezone -c '\dt'

systemctl start firezone.service
systemctl status firezone.service
journalctl -xeu firezone
