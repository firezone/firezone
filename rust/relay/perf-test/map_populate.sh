#!/bin/bash

# Helper script to populate eBPF maps for TURN relay testing
# This creates channel bindings between clients and gateways

set -e

# Configuration
# Use the IP of the interface where eBPF is attached (enp1s0)
RELAY_IP4="${RELAY_IP4:-192.168.1.209}"
RELAY_IP6="${RELAY_IP6:-2600:1700:3ecb:2410::45}"
CLIENT_PORT=52625
GATEWAY_PORT=52626
CHANNEL_NUM=0x4000 # 16384 in decimal
ALLOCATION_PORT=50000

# Map names as they appear in the eBPF program
CHAN_TO_UDP_44="CHAN_TO_UDP_44"
UDP_TO_CHAN_44="UDP_TO_CHAN_44"
CHAN_TO_UDP_66="CHAN_TO_UDP_66"
UDP_TO_CHAN_66="UDP_TO_CHAN_66"
CHAN_TO_UDP_46="CHAN_TO_UDP_46"
UDP_TO_CHAN_46="UDP_TO_CHAN_46"
CHAN_TO_UDP_64="CHAN_TO_UDP_64"
UDP_TO_CHAN_64="UDP_TO_CHAN_64"

# Find the map IDs
find_map_id() {
    local map_name=$1
    # Extract the ID from lines like "1780: hash  name CHAN_TO_UDP_44  flags 0x0"
    bpftool map show | grep "name $map_name " | awk -F: '{print $1}' | head -1
}

# Convert IP address to hex bytes with spaces
ip4_to_hex() {
    printf "%02x %02x %02x %02x" $(echo $1 | tr '.' ' ')
}

ip6_to_hex() {
    # Expand IPv6 address and convert to hex with spaces
    python3 -c "import ipaddress; h=''.join(['%02x' % int(b) for b in ipaddress.ip_address('$1').packed]); print(' '.join([h[i:i+2] for i in range(0, len(h), 2)]))"
}

# Convert port to hex (big-endian) with spaces
port_to_hex() {
    local port=$1
    printf "%02x %02x" $((port >> 8)) $((port & 0xFF))
}

# Helper to update a map entry
update_map() {
    local map_id=$1
    local key=$2
    local value=$3

    echo "Updating map $map_id with key=$key value=$value"
    bpftool map update id $map_id key hex $key value hex $value
}

# Setup IPv4 to IPv4 channel binding
setup_ipv4_to_ipv4() {
    echo "Setting up IPv4 to IPv4 channel binding..."

    local chan_to_udp_id=$(find_map_id $CHAN_TO_UDP_44)
    local udp_to_chan_id=$(find_map_id $UDP_TO_CHAN_44)

    if [ -z "$chan_to_udp_id" ] || [ -z "$udp_to_chan_id" ]; then
        echo "Error: Could not find IPv4-IPv4 maps"
        return 1
    fi

    # ClientAndChannelV4 key: ipv4_address[4] + port[2] + channel[2]
    local client_key="$(ip4_to_hex $RELAY_IP4) $(port_to_hex $CLIENT_PORT) $(port_to_hex $CHANNEL_NUM)"

    # PortAndPeerV4 value: ipv4_address[4] + allocation_port[2] + peer_port[2]
    local peer_value="$(ip4_to_hex $RELAY_IP4) $(port_to_hex $ALLOCATION_PORT) $(port_to_hex $GATEWAY_PORT)"

    # Update CHAN_TO_UDP_44
    update_map $chan_to_udp_id "$client_key" "$peer_value"

    # PortAndPeerV4 key: ipv4_address[4] + allocation_port[2] + peer_port[2]
    local udp_key="$(ip4_to_hex $RELAY_IP4) $(port_to_hex $ALLOCATION_PORT) $(port_to_hex $GATEWAY_PORT)"

    # Update UDP_TO_CHAN_44
    update_map $udp_to_chan_id "$udp_key" "$client_key"
}

# Setup IPv6 to IPv6 channel binding
setup_ipv6_to_ipv6() {
    echo "Setting up IPv6 to IPv6 channel binding..."

    local chan_to_udp_id=$(find_map_id $CHAN_TO_UDP_66)
    local udp_to_chan_id=$(find_map_id $UDP_TO_CHAN_66)

    if [ -z "$chan_to_udp_id" ] || [ -z "$udp_to_chan_id" ]; then
        echo "Error: Could not find IPv6-IPv6 maps"
        return 1
    fi

    # ClientAndChannelV6 key: ipv6_address[16] + port[2] + channel[2]
    local client_key="$(ip6_to_hex $RELAY_IP6) $(port_to_hex $CLIENT_PORT) $(port_to_hex $CHANNEL_NUM)"

    # PortAndPeerV6 value: ipv6_address[16] + allocation_port[2] + peer_port[2]
    local peer_value="$(ip6_to_hex $RELAY_IP6) $(port_to_hex $ALLOCATION_PORT) $(port_to_hex $GATEWAY_PORT)"

    # Update CHAN_TO_UDP_66
    update_map $chan_to_udp_id "$client_key" "$peer_value"

    # PortAndPeerV6 key: ipv6_address[16] + allocation_port[2] + peer_port[2]
    local udp_key="$(ip6_to_hex $RELAY_IP6) $(port_to_hex $ALLOCATION_PORT) $(port_to_hex $GATEWAY_PORT)"

    # Update UDP_TO_CHAN_66
    update_map $udp_to_chan_id "$udp_key" "$client_key"
}

# Setup IPv4 to IPv6 channel binding
setup_ipv4_to_ipv6() {
    echo "Setting up IPv4 to IPv6 channel binding..."

    local chan_to_udp_id=$(find_map_id $CHAN_TO_UDP_46)
    local udp_to_chan_id=$(find_map_id $UDP_TO_CHAN_64)

    if [ -z "$chan_to_udp_id" ] || [ -z "$udp_to_chan_id" ]; then
        echo "Error: Could not find IPv4-IPv6 cross-stack maps"
        return 1
    fi

    # ClientAndChannelV4 key: ipv4_address[4] + port[2] + channel[2]
    local client_key="$(ip4_to_hex $RELAY_IP4) $(port_to_hex $CLIENT_PORT) $(port_to_hex $CHANNEL_NUM)"

    # PortAndPeerV6 value: ipv6_address[16] + allocation_port[2] + peer_port[2]
    local peer_value="$(ip6_to_hex $RELAY_IP6) $(port_to_hex $ALLOCATION_PORT) $(port_to_hex $GATEWAY_PORT)"

    # Update CHAN_TO_UDP_46
    update_map $chan_to_udp_id "$client_key" "$peer_value"

    # PortAndPeerV6 key for reverse mapping
    local udp_key="$(ip6_to_hex $RELAY_IP6) $(port_to_hex $ALLOCATION_PORT) $(port_to_hex $GATEWAY_PORT)"

    # ClientAndChannelV6 value for reverse (gateway is IPv6)
    local client_v6_value="$(ip6_to_hex $RELAY_IP6) $(port_to_hex $CLIENT_PORT) $(port_to_hex $CHANNEL_NUM)"

    # Update UDP_TO_CHAN_64
    update_map $udp_to_chan_id "$udp_key" "$client_v6_value"
}

# Setup IPv6 to IPv4 channel binding
setup_ipv6_to_ipv4() {
    echo "Setting up IPv6 to IPv4 channel binding..."

    local chan_to_udp_id=$(find_map_id $CHAN_TO_UDP_64)
    local udp_to_chan_id=$(find_map_id $UDP_TO_CHAN_46)

    if [ -z "$chan_to_udp_id" ] || [ -z "$udp_to_chan_id" ]; then
        echo "Error: Could not find IPv6-IPv4 cross-stack maps"
        return 1
    fi

    # ClientAndChannelV6 key: ipv6_address[16] + port[2] + channel[2]
    local client_key="$(ip6_to_hex $RELAY_IP6) $(port_to_hex $CLIENT_PORT) $(port_to_hex $CHANNEL_NUM)"

    # PortAndPeerV4 value: ipv4_address[4] + allocation_port[2] + peer_port[2]
    local peer_value="$(ip4_to_hex $RELAY_IP4) $(port_to_hex $ALLOCATION_PORT) $(port_to_hex $GATEWAY_PORT)"

    # Update CHAN_TO_UDP_64
    update_map $chan_to_udp_id "$client_key" "$peer_value"

    # PortAndPeerV4 key for reverse mapping
    local udp_key="$(ip4_to_hex $RELAY_IP4) $(port_to_hex $ALLOCATION_PORT) $(port_to_hex $GATEWAY_PORT)"

    # ClientAndChannelV4 value for reverse (gateway is IPv4)
    local client_v4_value="$(ip4_to_hex $RELAY_IP4) $(port_to_hex $CLIENT_PORT) $(port_to_hex $CHANNEL_NUM)"

    # Update UDP_TO_CHAN_46
    update_map $udp_to_chan_id "$udp_key" "$client_v4_value"
}

# Main function
main() {
    local scenario=${1:-all}

    # Check if bpftool is available
    if ! command -v bpftool &>/dev/null; then
        echo "Error: bpftool is not installed"
        exit 1
    fi

    # Check if Python is available for IPv6 conversion
    if ! command -v python3 &>/dev/null; then
        echo "Error: python3 is not installed (needed for IPv6 address conversion)"
        exit 1
    fi

    case $scenario in
    ipv4)
        setup_ipv4_to_ipv4
        ;;
    ipv6)
        setup_ipv6_to_ipv6
        ;;
    ipv4-to-ipv6)
        setup_ipv4_to_ipv6
        ;;
    ipv6-to-ipv4)
        setup_ipv6_to_ipv4
        ;;
    all)
        setup_ipv4_to_ipv4
        setup_ipv6_to_ipv6
        setup_ipv4_to_ipv6
        setup_ipv6_to_ipv4
        ;;
    *)
        echo "Usage: $0 [ipv4|ipv6|ipv4-to-ipv6|ipv6-to-ipv4|all]"
        exit 1
        ;;
    esac

    echo "Map population complete!"
}

main "$@"

