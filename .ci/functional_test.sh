#!/usr/bin/env bash
set -x

sudo apt-get update
sudo apt-get install -y -q postgresql \
  wireguard iptables net-tools curl ca-certificates
sudo systemctl start postgresql
sudo dpkg -i *.deb

echo "Enabling service"
sudo systemctl start firezone

# Wait for app to start
# XXX: Remove sleeps
sleep 10

echo "Service status"
sudo systemctl status firezone.service

echo "Printing service logs"
sudo journalctl -u firezone.service

echo "Trying to load homepage"
curl -i -vvv -k https://$(hostname):8800/

echo "Printing SSL debug info"
openssl s_client -connect $(hostname):8800 -servername $(hostname) -showcerts -prexit

echo "Removing package"
sudo apt-get remove firezone

echo "Checking if directory was removed"
if [ -d /opt/firezone ]; then
  echo "Package removal issue"
  exit 1
fi

echo "Checking if database was dropped"
if $(sudo su postgres -c "psql -lqt | cut -d \| -f 1 | grep -qw firezone"); then
  echo "Database still exists"
  exit 1
fi
