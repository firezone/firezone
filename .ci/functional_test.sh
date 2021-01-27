#!/usr/bin/env bash
set -x

sudo apt-get update
sudo apt-get install -y postgresql \
  wireguard iptables net-tools curl ca-certificates
sudo systemctl start postgresql
sudo dpkg -i fireguard*.deb

echo "Enabling service..."
sudo systemctl start fireguard

sudo journalctl -xe fireguard.service
sudo systemctl status fireguard.service

# Wait for app to start
sleep 10

echo "Printing service status..."
sudo journalctl -u fireguard.service

echo "Trying to load homepage..."
curl -i -vvv -k https://$(hostname):8800/

echo "Printing SSL debug info"
openssl s_client -connect $(hostname):8800 -servername $(hostname) -showcerts -prexit
