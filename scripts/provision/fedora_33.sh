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
# Fix postgres login
cat <<EOT > /var/lib/pgsql/data/pg_hba.conf
local   all             all                                     peer
host    all             all             127.0.0.1/32            md5
host    all             all             ::1/128                 md5
EOT
systemctl enable postgresql
systemctl restart postgresql

file=(/tmp/firezone*.tar.gz)
/tmp/install.sh /tmp/$file



# systemctl start firezone.service
# systemctl status firezone.service
# journalctl -xeu firezone
