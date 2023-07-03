#!/bin/sh
if [ $PACKAGE_NAME = "gateway" ]; then
  IFACE="utun"
  iptables -A FORWARD -i $IFACE -j ACCEPT; iptables -A FORWARD -o $IFACE -j ACCEPT; iptables -t nat -A POSTROUTING -o eth+ -j MASQUERADE
fi
