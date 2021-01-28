#!/usr/bin/env bash
set -x

sudo apt-get update
sudo apt-get install -y postgresql \
  wireguard iptables net-tools curl ca-certificates
sudo systemctl start postgresql
sudo dpkg -i fireguard*.deb

echo "Enabling service..."
sudo systemctl start fireguard

# Wait for app to start
sleep 10

echo "Service status..."
sudo systemctl status fireguard.service

echo "Printing service logs..."
sudo journalctl -u fireguard.service

echo "Trying to load homepage..."
curl -i -vvv -k https://$(hostname):8800/

echo "Printing SSL debug info"
openssl s_client -connect $(hostname):8800 -servername $(hostname) -showcerts -prexit
