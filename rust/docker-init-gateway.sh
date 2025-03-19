#!/bin/sh

if [ -f "${FIREZONE_TOKEN}" ]; then
    FIREZONE_TOKEN="$(cat "${FIREZONE_TOKEN}")"
    export FIREZONE_TOKEN
fi

IFACE="tun-firezone"
# Enable masquerading for Firezone tunnel traffic
iptables -C FORWARD -i $IFACE -j ACCEPT > /dev/null 2>&1 || iptables -I FORWARD 1 -i $IFACE -j ACCEPT
iptables -C FORWARD -o $IFACE -j ACCEPT > /dev/null 2>&1 || iptables -I FORWARD 1 -o $IFACE -j ACCEPT
iptables -t nat -C POSTROUTING -s 100.64.0.0/11 -o e+ -j MASQUERADE > /dev/null 2>&1 || iptables -t nat -A POSTROUTING -s 100.64.0.0/11 -o e+ -j MASQUERADE
iptables -t nat -C POSTROUTING -s 100.64.0.0/11 -o w+ -j MASQUERADE > /dev/null 2>&1 || iptables -t nat -A POSTROUTING -s 100.64.0.0/11 -o w+ -j MASQUERADE
ip6tables -C FORWARD -i $IFACE -j ACCEPT > /dev/null 2>&1 || ip6tables -I FORWARD 1 -i $IFACE -j ACCEPT
ip6tables -C FORWARD -o $IFACE -j ACCEPT > /dev/null 2>&1 || ip6tables -I FORWARD 1 -o $IFACE -j ACCEPT
ip6tables -t nat -C POSTROUTING -s fd00:2021:1111::/107 -o e+ -j MASQUERADE > /dev/null 2>&1 || ip6tables -t nat -A POSTROUTING -s fd00:2021:1111::/107 -o e+ -j MASQUERADE
ip6tables -t nat -C POSTROUTING -s fd00:2021:1111::/107 -o w+ -j MASQUERADE > /dev/null 2>&1 || ip6tables -t nat -A POSTROUTING -s fd00:2021:1111::/107 -o w+ -j MASQUERADE

exec "$@"
