#!/bin/bash

# Setup network namespaces for eBPF relay testing
# Creates isolated network environments that route through the host

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Namespace and interface names
NS_CLIENT="relay-client"
NS_GATEWAY="relay-gateway"
VETH_CLIENT="veth-client"
VETH_HOST_CLIENT="veth-hclient"
VETH_GATEWAY="veth-gateway"  
VETH_HOST_GATEWAY="veth-hgateway"
BRIDGE="relay-bridge"

# IP configuration
BRIDGE_IP="10.99.0.1"
CLIENT_IP="10.99.0.10"
GATEWAY_IP="10.99.0.20"
SUBNET="10.99.0.0/24"

# Ports
CLIENT_PORT=52625
GATEWAY_PORT=52626
ALLOCATION_PORT=50000
TURN_PORT=3478

print_status() {
    echo -e "${GREEN}[+]${NC} $1"
}

print_error() {
    echo -e "${RED}[!]${NC} $1"
}

setup_namespaces() {
    # Check if already setup
    if ip link show $BRIDGE &>/dev/null && \
       ip netns list | grep -q $NS_CLIENT && \
       ip netns list | grep -q $NS_GATEWAY; then
        print_status "Network namespaces already configured, skipping setup"
        return 0
    fi
    
    print_status "Creating network namespaces..."
    
    # Clean up any partial setup
    cleanup 2>/dev/null || true
    
    # Create namespaces
    ip netns add $NS_CLIENT
    ip netns add $NS_GATEWAY
    
    print_status "Creating bridge interface..."
    
    # Create bridge
    ip link add name $BRIDGE type bridge
    ip addr add ${BRIDGE_IP}/24 dev $BRIDGE
    ip link set $BRIDGE up
    
    print_status "Creating veth pairs..."
    
    # Create veth pairs
    ip link add $VETH_CLIENT type veth peer name $VETH_HOST_CLIENT
    ip link add $VETH_GATEWAY type veth peer name $VETH_HOST_GATEWAY
    
    # Connect host side to bridge
    ip link set $VETH_HOST_CLIENT master $BRIDGE
    ip link set $VETH_HOST_GATEWAY master $BRIDGE
    ip link set $VETH_HOST_CLIENT up
    ip link set $VETH_HOST_GATEWAY up
    
    print_status "Configuring client namespace..."
    
    # Move client veth to namespace and configure
    ip link set $VETH_CLIENT netns $NS_CLIENT
    ip netns exec $NS_CLIENT ip addr add ${CLIENT_IP}/24 dev $VETH_CLIENT
    ip netns exec $NS_CLIENT ip link set $VETH_CLIENT up
    ip netns exec $NS_CLIENT ip link set lo up
    ip netns exec $NS_CLIENT ip route add default via $BRIDGE_IP
    
    print_status "Configuring gateway namespace..."
    
    # Move gateway veth to namespace and configure
    ip link set $VETH_GATEWAY netns $NS_GATEWAY
    ip netns exec $NS_GATEWAY ip addr add ${GATEWAY_IP}/24 dev $VETH_GATEWAY
    ip netns exec $NS_GATEWAY ip link set $VETH_GATEWAY up
    ip netns exec $NS_GATEWAY ip link set lo up
    ip netns exec $NS_GATEWAY ip route add default via $BRIDGE_IP
    
    print_status "Enabling forwarding and NAT..."
    
    # Enable forwarding
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    
    # Setup NAT for namespaces to reach external networks (if needed)
    iptables -t nat -A POSTROUTING -s $SUBNET ! -d $SUBNET -j MASQUERADE
    iptables -A FORWARD -i $BRIDGE -j ACCEPT
    iptables -A FORWARD -o $BRIDGE -j ACCEPT
    
    print_status "Network namespace setup complete!"
    echo ""
    echo "  Client namespace: $NS_CLIENT ($CLIENT_IP)"
    echo "  Gateway namespace: $NS_GATEWAY ($GATEWAY_IP)"
    echo "  Bridge: $BRIDGE ($BRIDGE_IP)"
}

cleanup() {
    print_status "Cleaning up network namespaces..."
    
    # Remove iptables rules
    iptables -t nat -D POSTROUTING -s $SUBNET ! -d $SUBNET -j MASQUERADE 2>/dev/null || true
    iptables -D FORWARD -i $BRIDGE -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -o $BRIDGE -j ACCEPT 2>/dev/null || true
    
    # Delete namespaces (this also deletes the veth interfaces inside them)
    ip netns del $NS_CLIENT 2>/dev/null || true
    ip netns del $NS_GATEWAY 2>/dev/null || true
    
    # Delete bridge and remaining interfaces
    ip link del $BRIDGE 2>/dev/null || true
    ip link del $VETH_HOST_CLIENT 2>/dev/null || true
    ip link del $VETH_HOST_GATEWAY 2>/dev/null || true
    
    print_status "Cleanup complete"
}

status() {
    echo "=== Network Namespace Status ==="
    
    # Check namespaces
    if ip netns list | grep -q $NS_CLIENT; then
        echo -e "Client namespace: ${GREEN}exists${NC}"
        ip netns exec $NS_CLIENT ip addr show $VETH_CLIENT 2>/dev/null | grep inet || echo "  No IP configured"
    else
        echo -e "Client namespace: ${RED}not found${NC}"
    fi
    
    if ip netns list | grep -q $NS_GATEWAY; then
        echo -e "Gateway namespace: ${GREEN}exists${NC}"
        ip netns exec $NS_GATEWAY ip addr show $VETH_GATEWAY 2>/dev/null | grep inet || echo "  No IP configured"
    else
        echo -e "Gateway namespace: ${RED}not found${NC}"
    fi
    
    # Check bridge
    if ip link show $BRIDGE &>/dev/null; then
        echo -e "Bridge: ${GREEN}exists${NC}"
        ip addr show $BRIDGE | grep inet || echo "  No IP configured"
    else
        echo -e "Bridge: ${RED}not found${NC}"
    fi
    
    # Test connectivity
    if ip netns list | grep -q $NS_CLIENT && ip netns list | grep -q $NS_GATEWAY; then
        echo ""
        echo "Testing connectivity..."
        
        # Test client -> gateway
        if ip netns exec $NS_CLIENT ping -c 1 -W 1 $GATEWAY_IP &>/dev/null; then
            echo -e "  Client -> Gateway: ${GREEN}OK${NC}"
        else
            echo -e "  Client -> Gateway: ${RED}FAILED${NC}"
        fi
        
        # Test gateway -> client
        if ip netns exec $NS_GATEWAY ping -c 1 -W 1 $CLIENT_IP &>/dev/null; then
            echo -e "  Gateway -> Client: ${GREEN}OK${NC}"
        else
            echo -e "  Gateway -> Client: ${RED}FAILED${NC}"
        fi
        
        # Test client -> host
        if ip netns exec $NS_CLIENT ping -c 1 -W 1 $BRIDGE_IP &>/dev/null; then
            echo -e "  Client -> Host: ${GREEN}OK${NC}"
        else
            echo -e "  Client -> Host: ${RED}FAILED${NC}"
        fi
    fi
}

# Function to run commands in namespaces
run_in_client() {
    ip netns exec $NS_CLIENT "$@"
}

run_in_gateway() {
    ip netns exec $NS_GATEWAY "$@"
}

main() {
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run as root"
        exit 1
    fi
    
    case ${1:-setup} in
        setup)
            setup_namespaces
            ;;
        cleanup|teardown)
            cleanup
            ;;
        status)
            status
            ;;
        client)
            shift
            run_in_client "$@"
            ;;
        gateway)
            shift
            run_in_gateway "$@"
            ;;
        *)
            echo "Usage: $0 [setup|cleanup|status|client <cmd>|gateway <cmd>]"
            echo ""
            echo "Commands:"
            echo "  setup    - Create network namespaces and configure networking"
            echo "  cleanup  - Remove network namespaces and clean up"
            echo "  status   - Show current namespace status and connectivity"
            echo "  client   - Run command in client namespace"
            echo "  gateway  - Run command in gateway namespace"
            echo ""
            echo "Examples:"
            echo "  $0 setup"
            echo "  $0 client ip addr show"
            echo "  $0 gateway ping $CLIENT_IP"
            echo "  $0 cleanup"
            exit 1
            ;;
    esac
}

main "$@"