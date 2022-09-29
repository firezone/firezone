#!/bin/sh

ip link add dev wg-firezone type wireguard
ip address replace dev wg-firezone 10.3.2.1/24
ip -6 address replace dev wg-firezone fd00::3:2:1/120
ip link set mtu 1280 up dev wg-firezone

mix start
