#!/bin/sh

if [ -f "${FIREZONE_TOKEN}" ]; then
    FIREZONE_TOKEN="$(cat "${FIREZONE_TOKEN}")"
    export FIREZONE_TOKEN
fi

IFACE="tun-firezone"
# Enable masquerading for our TUN interface
iptables -C FORWARD -i $IFACE -j ACCEPT >/dev/null 2>&1 || iptables -A FORWARD -i $IFACE -j ACCEPT
iptables -C FORWARD -o $IFACE -j ACCEPT >/dev/null 2>&1 || iptables -A FORWARD -o $IFACE -j ACCEPT
iptables -t nat -C POSTROUTING -o e+ -j MASQUERADE >/dev/null 2>&1 || iptables -t nat -A POSTROUTING -o e+ -j MASQUERADE
iptables -t nat -C POSTROUTING -o w+ -j MASQUERADE >/dev/null 2>&1 || iptables -t nat -A POSTROUTING -o w+ -j MASQUERADE
ip6tables -C FORWARD -i $IFACE -j ACCEPT >/dev/null 2>&1 || ip6tables -A FORWARD -i $IFACE -j ACCEPT
ip6tables -C FORWARD -o $IFACE -j ACCEPT >/dev/null 2>&1 || ip6tables -A FORWARD -o $IFACE -j ACCEPT
ip6tables -t nat -C POSTROUTING -o e+ -j MASQUERADE >/dev/null 2>&1 || ip6tables -t nat -A POSTROUTING -o e+ -j MASQUERADE
ip6tables -t nat -C POSTROUTING -o w+ -j MASQUERADE >/dev/null 2>&1 || ip6tables -t nat -A POSTROUTING -o w+ -j MASQUERADE

exec "$@"
