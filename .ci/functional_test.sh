#!/usr/bin/env bash
set -e

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
output=$(sudo apt-get remove --purge firezone)

echo "Checking if config file was removed"
if [ -e /opt/firezone/config.env ]; then
  echo "Config removal issue"
  exit 1
fi

echo "Checking if instructions were printed on how to remove database and secrets"
if echo "$output" | grep 'Refusing to purge /etc/firezone/secret and drop database.'; then
  echo "Instructions printed"
else
  echo "Instructions not printed!"
  exit 1
fi
