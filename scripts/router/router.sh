#!/bin/bash

set -euo pipefail

# Get network configuration
INTERNAL_NET_V4=$(ip -4 --json route | jq -r '.[] | select(.dev == "internal") | select(.dst == "default" | not) | .dst')
INTERNAL_NET_V6=$(ip -6 --json route | jq -r '.[] | select(.dev == "internal") | select(.dst | startswith("fe80") | not) | select(.dst == "default" | not) | .dst')
PUBLIC_IPV4=$(ip -4 -json addr show internet | jq -r '.[0].addr_info[0].local')
PUBLIC_IPV6=$(ip -6 -json addr show internet | jq -r '.[0].addr_info[0].local')

# Validate required configuration
if [ -z "$INTERNAL_NET_V4" ]; then
    echo "Error: Failed to identify internal IPv4 subnet"
    exit 1
fi

if [ -z "$INTERNAL_NET_V6" ]; then
    echo "Error: Failed to identify internal IPv6 subnet"
    exit 1
fi

if [ -z "$PUBLIC_IPV4" ]; then
    echo "Error: Failed to get public IPv4"
    exit 1
fi

if [ -z "$PUBLIC_IPV6" ]; then
    echo "Error: Failed to get public IPv6"
    exit 1
fi

echo "INTERNAL_NET_V4 = $INTERNAL_NET_V4"
echo "INTERNAL_NET_V6 = $INTERNAL_NET_V6"
echo "PUBLIC_IPV4 = $PUBLIC_IPV4"
echo "PUBLIC_IPV6 = $PUBLIC_IPV6"

TEMPLATE_FILE="router.nft"
CONFIG_FILE="/tmp/router.nft"

# Copy template file to working config
cp "$TEMPLATE_FILE" "$CONFIG_FILE"

echo "add rule inet router postrouting ip saddr $INTERNAL_NET_V4 oifname \"internet\" masquerade ${MASQUERADE_TYPE:-}" >>"$CONFIG_FILE"
echo "add rule inet router postrouting ip6 saddr $INTERNAL_NET_V6 oifname \"internet\" masquerade ${MASQUERADE_TYPE:-}" >>"$CONFIG_FILE"

# Add port forwarding rules if specified
if [ -n "${PORT_FORWARDS:-}" ]; then
    echo "$PORT_FORWARDS" | tr ',' '\n' | while IFS=' ' read -r port internal_ip protocol; do
        if [ -z "$port" ] || [ -z "$internal_ip" ] || [ -z "$protocol" ]; then
            continue
        fi

        # Determine if internal IP is IPv4 or IPv6 and append rules to config file
        case "$internal_ip" in
        *:*) # IPv6 address
            echo "add rule inet router prerouting ip6 daddr $PUBLIC_IPV6 $protocol dport $port dnat to [$internal_ip]:$port" >>"$CONFIG_FILE"
            echo "add rule inet router input ip6 daddr $internal_ip $protocol dport $port accept" >>"$CONFIG_FILE"
            ;;
        *) # IPv4 address
            echo "add rule inet router prerouting ip daddr $PUBLIC_IPV4 $protocol dport $port dnat to $internal_ip:$port" >>"$CONFIG_FILE"
            echo "add rule inet router input ip daddr $internal_ip $protocol dport $port accept" >>"$CONFIG_FILE"
            ;;
        esac
    done
fi

# Add configurable latency if specified
if [ -n "${NETWORK_LATENCY_MS:-}" ]; then
    LATENCY=$((NETWORK_LATENCY_MS / 2)) # Latency is only applied to outbound packets. To achieve the actual configured latency, we apply half of it to each interface.

    tc qdisc add dev internet root netem delay "${LATENCY}ms"
    tc qdisc add dev internal root netem delay "${LATENCY}ms"
fi

ip link set dev internal txqueuelen 100000
ip link set dev internet txqueuelen 100000

echo "-----------------------------------------------------------------------------------------------"
cat "$CONFIG_FILE"
echo "-----------------------------------------------------------------------------------------------"

nft -f "$CONFIG_FILE"

rm "$CONFIG_FILE"

for iface in internal internet; do
    # Enable RPS (Receive Packet Steering) to always use CPU 1 to handle packets.
    # This prevents packet reordering where otherwise the CPU which handles the interrupt would handle the packet.
    echo 1 >"/sys/class/net/$iface/queues/rx-0/rps_cpus" 2>/dev/null
done

echo "1" >/tmp/setup_done # Health check marker

# Keep container running
exec tail -f /dev/null
