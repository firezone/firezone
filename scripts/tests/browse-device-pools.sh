#!/usr/bin/env bash

# Browses the device pools in `firezone.network` with PTR queries from the primary
# client and resolves the member a pool lists.

source "./scripts/tests/lib.sh"

# Matches the ipv4 pinned for the pool member device in elixir/priv/repo/seeds.exs
pool_member_ip="100.64.0.2"

echo "# firezone.network should list the pools the client may use"
pools=$(client_nslookup "-type=ptr firezone.network")
grep "ci-static-pool\.firezone\.network" <<<"$pools"

# The primary client runs as a service account, which is not in Everyone, the only group granted `Your devices`.
echo "# firezone.network should not list the pools the client may not use"
(grep "your-devices\.firezone\.network" <<<"$pools") && exit 1

echo "# The pool should list its only member"
readarray -t members < <(client_nslookup "-type=ptr ci-static-pool.firezone.network" | awk '/name = / { print $NF }')
assert_eq "${#members[@]}" 1

echo "# The listed member should resolve to $pool_member_ip"
client_nslookup "-type=a ${members[0]}" | grep -Fw "$pool_member_ip"

echo "# Primary client should be able to ping the pool member by its name"
client_ping "${members[0]}"

echo "# An unknown pool should not exist"
client_nslookup "-type=ptr does-not-exist.firezone.network" | grep NXDOMAIN
