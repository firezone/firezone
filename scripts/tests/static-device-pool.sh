#!/usr/bin/env bash

# In static device pools the member is addressed by its tun IP.
# Pings the pool member at its pinned tun IP and asserts the gateway saw no flow, proving the P2P path.

source "./scripts/tests/lib.sh"

# Matches the ipv4 pinned for the pool member device in elixir/priv/repo/seeds.exs
pool_member_ip="100.64.0.2"

echo "# Primary client should be able to ping the pool member at $pool_member_ip"
client_ping "$pool_member_ip"

echo "# Gateway should have observed no flows (P2P path proven)"
readarray -t icmp_flows < <(get_flow_logs "icmp")
assert_eq "${#icmp_flows[@]}" "0"
