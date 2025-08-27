#!/bin/bash

# eBPF TURN relay throughput test
# Two modes: namespaced (local testing) or direct (physical NIC)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Test mode
MODE=${MODE:-namespaced}  # namespaced or direct

# Network configuration
if [ "$MODE" = "namespaced" ]; then
    # Namespace configuration
    BRIDGE_IP="10.99.0.1"
    CLIENT_IP="10.99.0.10"
    GATEWAY_IP="10.99.0.20"
    NS_CLIENT="relay-client"
    NS_GATEWAY="relay-gateway"
    BRIDGE="relay-bridge"
else
    # Direct mode - use real IPs
    RELAY_IP=${RELAY_IP:-$(ip route get 1 | awk '{print $7;exit}')}
    CLIENT_IP=${CLIENT_IP:-$RELAY_IP}
    GATEWAY_IP=${GATEWAY_IP:-$RELAY_IP}
    BRIDGE_IP=$RELAY_IP
fi

CLIENT_PORT=52625
GATEWAY_PORT=52626
ALLOCATION_PORT=50000
TURN_PORT=3478

# Test parameters
PAYLOAD_SIZE=${PAYLOAD_SIZE:-1400}
DURATION=${DURATION:-10}
PACKET_COUNT=${PACKET_COUNT:-10000}

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# Setup for namespaced mode
setup_namespaced() {
    echo "Setting up network namespaces..."
    "$SCRIPT_DIR/setup_netns.sh" setup
    sleep 1
}

# Populate eBPF maps
populate_maps() {
    echo "Populating eBPF maps..."
    
    # Find map IDs
    CHAN_TO_UDP_44=$(sudo bpftool map show | grep "name CHAN_TO_UDP_44 " | awk -F: '{print $1}')
    UDP_TO_CHAN_44=$(sudo bpftool map show | grep "name UDP_TO_CHAN_44 " | awk -F: '{print $1}')
    
    if [ -z "$CHAN_TO_UDP_44" ] || [ -z "$UDP_TO_CHAN_44" ]; then
        echo "Error: Could not find eBPF maps. Is relay running with EBPF_OFFLOADING?"
        exit 1
    fi
    
    # Convert IPs to hex
    CLIENT_HEX=$(printf "%02x %02x %02x %02x" $(echo $CLIENT_IP | tr '.' ' '))
    GATEWAY_HEX=$(printf "%02x %02x %02x %02x" $(echo $GATEWAY_IP | tr '.' ' '))
    
    # ClientAndChannelV4 key: client_ip[4] + port[2] + channel[2]
    CLIENT_KEY="$CLIENT_HEX cd 91 40 00"  # port 52625 + channel 0x4000
    
    # PortAndPeerV4 value: gateway_ip[4] + allocation_port[2] + peer_port[2]  
    PEER_VALUE="$GATEWAY_HEX c3 50 cd 92"  # port 50000 + port 52626
    
    sudo bpftool map update id $CHAN_TO_UDP_44 key hex $CLIENT_KEY value hex $PEER_VALUE
    sudo bpftool map update id $UDP_TO_CHAN_44 key hex $PEER_VALUE value hex $CLIENT_KEY
    
    echo "Maps populated"
}




# Throughput test
run_throughput_test() {
    echo "Running throughput test"
    echo "  Mode: $MODE"
    echo "  Duration: $DURATION seconds"
    echo "  Payload: $PAYLOAD_SIZE bytes"
    
    # Create channel data packet
    local packet_file=$(mktemp)
    dd if=/dev/urandom of=${packet_file}.payload bs=1 count=$PAYLOAD_SIZE 2>/dev/null
    (
        printf "\\$(printf '%03o' 64)"   # 0x40
        printf "\\$(printf '%03o' 0)"    # 0x00
        printf "\\$(printf '%03o' $(($PAYLOAD_SIZE >> 8)))"
        printf "\\$(printf '%03o' $(($PAYLOAD_SIZE & 0xFF)))"
        cat ${packet_file}.payload
    ) > $packet_file
    rm -f ${packet_file}.payload
    
    # Setup receiver command based on mode
    if [ "$MODE" = "namespaced" ]; then
        RECEIVER_CMD="sudo ip netns exec $NS_GATEWAY"
        SENDER_CMD="sudo ip netns exec $NS_CLIENT"
    else
        RECEIVER_CMD=""
        SENDER_CMD=""
    fi
    
    # Start receiver
    $RECEIVER_CMD timeout $((DURATION + 2)) \
        nc -u -l -p $GATEWAY_PORT > /tmp/gateway_received.txt 2>&1 &
    local receiver_pid=$!
    
    sleep 1
    
    # Send packets for duration
    local start_time=$(date +%s.%N)
    local end_time=$(echo "$start_time + $DURATION" | bc)
    local count=0
    
    echo "Sending packets..."
    while (( $(echo "$(date +%s.%N) < $end_time" | bc -l) )); do
        for i in {1..100}; do
            cat $packet_file | $SENDER_CMD \
                nc -u -s $CLIENT_IP -p $CLIENT_PORT -w0 $BRIDGE_IP $TURN_PORT &
        done
        wait
        count=$((count + 100))
        
        if [ $((count % 1000)) -eq 0 ]; then
            echo "  Sent $count packets"
        fi
    done
    
    local actual_duration=$(echo "$(date +%s.%N) - $start_time" | bc)
    
    # Stop receiver
    sleep 1
    kill $receiver_pid 2>/dev/null || true
    
    # Calculate results
    local bytes_received=0
    if [ -f /tmp/gateway_received.txt ]; then
        bytes_received=$(wc -c < /tmp/gateway_received.txt)
    fi
    
    local pps=$(echo "scale=0; $count / $actual_duration" | bc)
    local mbps_sent=$(echo "scale=2; ($count * ($PAYLOAD_SIZE + 4) * 8) / ($actual_duration * 1000000)" | bc)
    local mbps_recv=$(echo "scale=2; ($bytes_received * 8) / ($actual_duration * 1000000)" | bc)
    
    echo ""
    echo "=== RESULTS ==="
    echo "Duration: ${actual_duration}s"
    echo "Packets sent: $count"
    echo "Bytes received: $bytes_received"
    echo "Packets/sec: $pps"
    echo "Throughput (sent): $mbps_sent Mbps"
    echo "Throughput (received): $mbps_recv Mbps"
    echo "==============="
    
    rm -f $packet_file
}

# Cleanup
cleanup() {
    echo "Cleaning up..."
    
    # Kill any remaining nc processes
    sudo pkill -f "nc.*52625" 2>/dev/null || true
    sudo pkill -f "nc.*52626" 2>/dev/null || true
    
    # Remove temp files
    rm -f /tmp/gateway_received.txt
    
    # Cleanup namespaces if in namespaced mode
    if [ "$MODE" = "namespaced" ]; then
        "$SCRIPT_DIR/setup_netns.sh" cleanup 2>/dev/null || true
    fi
}


# Main
main() {
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        echo "Error: This script must be run as root"
        exit 1
    fi
    
    echo "=== eBPF TURN Relay Throughput Test ==="
    echo ""
    
    # Setup based on mode
    if [ "$MODE" = "namespaced" ]; then
        setup_namespaced
        echo "Start relay with: EBPF_OFFLOADING=$BRIDGE EBPF_ATTACH_MODE=generic ./relay"
    else
        echo "Direct mode - using host network"
        echo "Start relay with: EBPF_OFFLOADING=<interface> ./relay"
    fi
    
    echo ""
    read -p "Is the relay running with eBPF enabled? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Please start the relay first"
        exit 1
    fi
    
    # Populate maps and run test
    populate_maps
    echo ""
    run_throughput_test
    
    # Cleanup on exit
    trap cleanup EXIT
}

# Parse arguments
if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    echo "Usage: $0 [namespaced|direct]"
    echo ""
    echo "Modes:"
    echo "  namespaced - Local testing with network namespaces (default)"
    echo "  direct     - Testing on physical NIC"
    echo ""
    echo "Environment variables:"
    echo "  MODE         - namespaced or direct (default: namespaced)"
    echo "  PAYLOAD_SIZE - Packet payload size (default: 1400)"
    echo "  DURATION     - Test duration in seconds (default: 10)"
    echo ""
    echo "Examples:"
    echo "  # Namespace test"
    echo "  sudo $0 namespaced"
    echo ""
    echo "  # Direct mode with custom settings"
    echo "  MODE=direct RELAY_IP=192.168.1.100 sudo $0"
    echo ""
    echo "  # High throughput test"
    echo "  PAYLOAD_SIZE=64 DURATION=30 sudo $0"
    exit 0
fi

if [ -n "$1" ]; then
    MODE=$1
fi

main