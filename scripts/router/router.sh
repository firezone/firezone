#!/bin/bash

set -euo pipefail

# IPv6 may be unavailable altogether (e.g. kernels booted with `ipv6.disable=1`).
if [ -f /proc/net/if_inet6 ]; then
    IPV6_SUPPORTED=1
else
    IPV6_SUPPORTED=0
    echo "Kernel has IPv6 disabled; configuring IPv4 only"
fi

# Get network configuration
INTERNAL_NET_V4=$(ip -4 --json route | jq -r '.[] | select(.dev == "internal") | select(.dst == "default" | not) | .dst')
PUBLIC_IPV4=$(ip -4 -json addr show internet | jq -r '.[0].addr_info[0].local')

if [ "$IPV6_SUPPORTED" = "1" ]; then
    INTERNAL_NET_V6=$(ip -6 --json route | jq -r '.[] | select(.dev == "internal") | select(.dst | startswith("fe80") | not) | select(.dst == "default" | not) | .dst')
    PUBLIC_IPV6=$(ip -6 -json addr show internet | jq -r '.[0].addr_info[0].local')
else
    INTERNAL_NET_V6=""
    PUBLIC_IPV6=""
fi

# Validate required configuration
if [ -z "$INTERNAL_NET_V4" ]; then
    echo "Error: Failed to identify internal IPv4 subnet"
    exit 1
fi

if [ "$IPV6_SUPPORTED" = "1" ] && [ -z "$INTERNAL_NET_V6" ]; then
    echo "Error: Failed to identify internal IPv6 subnet"
    exit 1
fi

if [ -z "$PUBLIC_IPV4" ]; then
    echo "Error: Failed to get public IPv4"
    exit 1
fi

if [ "$IPV6_SUPPORTED" = "1" ] && [ -z "$PUBLIC_IPV6" ]; then
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
if [ -n "$INTERNAL_NET_V6" ]; then
    echo "add rule inet router postrouting ip6 saddr $INTERNAL_NET_V6 oifname \"internet\" masquerade ${MASQUERADE_TYPE:-}" >>"$CONFIG_FILE"
fi

# Add port forwarding rules if specified
if [ -n "${PORT_FORWARDS:-}" ]; then
    echo "$PORT_FORWARDS" | tr ',' '\n' | while IFS=' ' read -r port internal_ip protocol; do
        if [ -z "$port" ] || [ -z "$internal_ip" ] || [ -z "$protocol" ]; then
            continue
        fi

        # Determine if internal IP is IPv4 or IPv6 and append rules to config file
        case "$internal_ip" in
        *:*) # IPv6 address
            if [ -z "$PUBLIC_IPV6" ]; then
                continue
            fi

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

# Add configurable latency if specified.
if [ "${NETWORK_LATENCY_MS:-0}" -gt 0 ]; then
    LATENCY=$((NETWORK_LATENCY_MS / 2)) # Latency is only applied to outbound packets. To achieve the actual configured latency, we apply half of it to each interface.

    tc qdisc add dev internet root netem delay "${LATENCY}ms" limit 100000
    tc qdisc add dev internal root netem delay "${LATENCY}ms" limit 100000
fi

ip link set dev internal txqueuelen 100000
ip link set dev internet txqueuelen 100000

echo "-----------------------------------------------------------------------------------------------"
cat "$CONFIG_FILE"
echo "-----------------------------------------------------------------------------------------------"

nft -f "$CONFIG_FILE"

rm "$CONFIG_FILE"

# Software flow offload. Established TCP/UDP flows (added in the forward chain)
# take a fast forwarding path that skips conntrack re-eval + the ruleset on every
# packet. Requires CONFIG_NF_FLOW_TABLE, which some VM kernels lack (e.g. Claude
# Code web), so apply it only when the kernel supports it.
if nft add flowtable inet router ft '{ hook ingress priority filter; devices = { internal, internet }; }' 2>/dev/null; then
    nft add rule inet router forward 'meta l4proto { tcp, udp } flow add @ft'
else
    echo "Kernel lacks nftables flowtable support; skipping software flow offload"
fi

# Pin RPS (Receive Packet Steering) to a single host CPU so all of this router's
# RX is processed on one core. This preserves packet ordering; otherwise whichever
# CPU handled the interrupt would process the packet, causing reordering.
#
# Derive that CPU *uniquely* from the public interface's assigned address (unique
# per router on the shared `internet` network), so each router lands on a different
# core and the per-hop softirq load spreads across cores instead of piling every
# hop onto CPU0. Wrapping modulo the online CPU count keeps this working on
# few-core hosts (e.g. 2-core CI, where it degrades to alternating cores).
ncpus=$(nproc)
rps_cpu=$(( ${PUBLIC_IPV4##*.} % ncpus ))
rps_mask=$(printf '%x' $(( 1 << rps_cpu )))
echo "Pinning RPS to CPU ${rps_cpu}/${ncpus} (mask ${rps_mask}) from ${PUBLIC_IPV4}"

for iface in internal internet; do
    echo "$rps_mask" >"/sys/class/net/$iface/queues/rx-0/rps_cpus" 2>/dev/null
done

echo "1" >/tmp/setup_done # Health check marker

# Keep container running
exec tail -f /dev/null
