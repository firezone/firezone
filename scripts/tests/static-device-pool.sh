#!/usr/bin/env bash

# In static device pools the member is addressed by its tun IP.
# Pings the pool member at its pinned tun IP from the primary client.

source "./scripts/tests/lib.sh"

# Matches the ipv4 pinned for the pool member device in elixir/priv/repo/seeds.exs
pool_member_ip="100.64.0.2"

echo "# Primary client should be able to ping the pool member at $pool_member_ip"
client_ping "$pool_member_ip"
