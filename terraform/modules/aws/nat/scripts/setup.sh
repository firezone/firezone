#!/bin/bash

set -xe

sudo apt-get update

# Enable IP forwarding
echo "net.ipv4.ip_forward = 1" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# Setup iptables NAT
sudo iptables -t nat -A POSTROUTING -o ens5 -s 0.0.0.0/0 -j MASQUERADE

# Save iptables rules in case of reboot
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
sudo systemctl enable --now netfilter-persistent.service
sudo mkdir -p /etc/iptables
sudo /usr/bin/iptables-save | sudo tee -a /etc/iptables/rules.v4
