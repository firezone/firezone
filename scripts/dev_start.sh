#!/bin/sh

ip link add dev wg-firezone type wireguard
ip address replace dev wg-firezone 100.64.0.1/10
ip -6 address replace dev wg-firezone fd00::1/106
ip link set mtu 1280 up dev wg-firezone

mix start
