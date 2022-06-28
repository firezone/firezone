#!/bin/bash

ip link add dev wg-firezone type wireguard
ip address add dev wg-firezone 10.3.2.1/24
ip link set up dev wg-firezone

mix start
