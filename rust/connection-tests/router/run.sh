#!/bin/sh

set -ex

# Set up NAT
nft add table ip nat
nft add chain ip nat postrouting { type nat hook postrouting priority 100 \; }
nft add rule ip nat postrouting masquerade

# Assumption after a long debugging session involving Gabi, Jamil and Thomas:
# On the same machine, the kernel cannot differentiate between incoming and outgoing packets across different network namespaces within the firewall and NAT mapping table.
# As a result, even UDP hole-punching is time-sensitive and we thus need to make sure that we first send a packet _out_ through the router before the other one is incoming.
# To achieve this, we set an absurdly high latency of 300ms for the WAN network.
tc qdisc add dev eth1 root netem delay 300ms

echo "1" > /tmp/setup_done # This will be checked by our docker HEALTHCHECK

conntrack --event --proto UDP --output timestamp # Display a real-time log of NAT events in the kernel.
