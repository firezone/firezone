#!/usr/bin/env bash
set -xe

sudo apt-get update
sudo apt-get install -y postgresql \
  wireguard iptables net-tools curl ca-certificates
sudo systemctl start postgresql

echo "Setting capabilities"
sudo setcap "cap_net_admin+ep" cloudfire
sudo setcap "cap_net_raw+ep" cloudfire
sudo setcap "cap_dac_read_search+ep" cloudfire
chmod +x cloudfire

file cloudfire

ls -alR ~/.cache/

./cloudfire &

# Wait for app to start
sleep 10

echo "Trying to load homepage..."
curl -i -vvv -k https://$(hostname):8800/

echo "Printing SSL debug info"
openssl s_client -connect $(hostname):8800 -servername $(hostname) -showcerts -prexit
