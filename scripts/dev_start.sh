#!/bin/bash

ip link add dev wg-firezone type wireguard
ip address add dev wg-firezone 10.3.2.1/24
ip -6 address add dev wg-firezone fd00::3:2:1/120
ip link set up dev wg-firezone

mix start
