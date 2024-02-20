#!/usr/bin/env bash

set -euox pipefail

#  Disallow traffic between gateway and client container
sudo iptables -I FORWARD 1 -s 172.28.0.100 -d 172.28.0.105 -j DROP
sudo iptables -I FORWARD 1 -s 172.28.0.105 -d 172.28.0.100 -j DROP
