#!/usr/bin/env bash

# In static device pools the member is addressed by its tun IP.
# Finds the tun IP of the pool member, pings it and asserts the gateway saw no flow, proving the P2P path.

source "./scripts/tests/lib.sh"

echo "# Pool member should be up and have its tun interface"
pool_member ip link | grep -q tun-firezone

echo "# Discover the pool member's tunnel IPv4"
pool_member_ip="$(pool_member sh -c "ip -4 -o addr show tun-firezone | awk '{split(\$4,a,\"/\"); print a[1]}'")"
assert_ne "$pool_member_ip" ""

echo "# Primary client should be able to ping the pool member at $pool_member_ip"
client_ping "$pool_member_ip"

echo "# Gateway should have observed no flows (P2P path proven)"
readarray -t icmp_flows < <(get_flow_logs "icmp")
assert_eq "${#icmp_flows[@]}" "0"
