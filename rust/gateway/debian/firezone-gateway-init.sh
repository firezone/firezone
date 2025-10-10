#!/bin/sh

set -ue

# Enable masquerading for Firezone tunnel traffic
iptables -C FORWARD -i tun-firezone -j ACCEPT >/dev/null 2>&1 || iptables -I FORWARD 1 -i tun-firezone -j ACCEPT
iptables -C FORWARD -o tun-firezone -j ACCEPT >/dev/null 2>&1 || iptables -I FORWARD 1 -o tun-firezone -j ACCEPT
iptables -t nat -C POSTROUTING -s 100.64.0.0/11 -o e+ -j MASQUERADE >/dev/null 2>&1 || iptables -t nat -A POSTROUTING -s 100.64.0.0/11 -o e+ -j MASQUERADE
iptables -t nat -C POSTROUTING -s 100.64.0.0/11 -o w+ -j MASQUERADE >/dev/null 2>&1 || iptables -t nat -A POSTROUTING -s 100.64.0.0/11 -o w+ -j MASQUERADE
ip6tables -C FORWARD -i tun-firezone -j ACCEPT >/dev/null 2>&1 || ip6tables -I FORWARD 1 -i tun-firezone -j ACCEPT
ip6tables -C FORWARD -o tun-firezone -j ACCEPT >/dev/null 2>&1 || ip6tables -I FORWARD 1 -o tun-firezone -j ACCEPT
ip6tables -t nat -C POSTROUTING -s fd00:2021:1111::/107 -o e+ -j MASQUERADE >/dev/null 2>&1 || ip6tables -t nat -A POSTROUTING -s fd00:2021:1111::/107 -o e+ -j MASQUERADE
ip6tables -t nat -C POSTROUTING -s fd00:2021:1111::/107 -o w+ -j MASQUERADE >/dev/null 2>&1 || ip6tables -t nat -A POSTROUTING -s fd00:2021:1111::/107 -o w+ -j MASQUERADE

# Enable packet forwarding for IPv4 and IPv6
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv4.conf.all.src_valid_mark=1
sysctl -w net.ipv6.conf.all.disable_ipv6=0
sysctl -w net.ipv6.conf.all.forwarding=1
sysctl -w net.ipv6.conf.default.forwarding=1
