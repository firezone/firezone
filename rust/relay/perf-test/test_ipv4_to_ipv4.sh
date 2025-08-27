#!/bin/bash

# IPv4 to IPv4 relay throughput test
# Tests both channel->udp and udp->channel directions

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
RELAY_IP="${RELAY_IP:-127.0.0.1}"
CLIENT_IP="${CLIENT_IP:-127.0.0.1}"
GATEWAY_IP="${GATEWAY_IP:-127.0.0.1}"
CLIENT_PORT=52625
GATEWAY_PORT=52626
ALLOCATION_PORT=50000
TURN_PORT=3478
PAYLOAD_SIZE=${PAYLOAD_SIZE:-1400}
DURATION=${DURATION:-10}

echo "=== IPv4 to IPv4 Relay Throughput Test ==="
echo "Relay IP: $RELAY_IP"
echo "Payload: $PAYLOAD_SIZE bytes"
echo "Duration: $DURATION seconds"
echo ""

# Populate eBPF maps for IPv4 to IPv4
echo "Populating eBPF maps for IPv4 to IPv4..."
sudo "$SCRIPT_DIR/map_populate.sh" ipv4

# Test 1: Channel Data -> UDP throughput
echo ""
echo "Test 1: Channel->UDP Throughput (Client to Gateway)"
echo "---------------------------------------------------"

# Create channel data packet
PACKET_FILE=$(mktemp)
dd if=/dev/urandom of=${PACKET_FILE}.payload bs=1 count=$PAYLOAD_SIZE 2>/dev/null
(
    printf "\\$(printf '%03o' 64)"   # 0x40
    printf "\\$(printf '%03o' 0)"    # 0x00
    printf "\\$(printf '%03o' $(($PAYLOAD_SIZE >> 8)))"
    printf "\\$(printf '%03o' $(($PAYLOAD_SIZE & 0xFF)))"
    cat ${PACKET_FILE}.payload
) > $PACKET_FILE
rm -f ${PACKET_FILE}.payload

# Start receiver
timeout $((DURATION + 2)) nc -u -l -p $GATEWAY_PORT > /tmp/gw_recv.txt 2>&1 &
RECEIVER_PID=$!
sleep 1

# Send packets for duration
START_TIME=$(date +%s.%N)
END_TIME=$(echo "$START_TIME + $DURATION" | bc)
COUNT=0

echo "Sending channel data packets..."
while (( $(echo "$(date +%s.%N) < $END_TIME" | bc -l) )); do
    for i in {1..100}; do
        cat $PACKET_FILE | nc -u -s $CLIENT_IP -p $CLIENT_PORT -w0 $RELAY_IP $TURN_PORT &
    done
    wait
    COUNT=$((COUNT + 100))
    [ $((COUNT % 1000)) -eq 0 ] && echo "  Sent $COUNT packets"
done

ACTUAL_DURATION=$(echo "$(date +%s.%N) - $START_TIME" | bc)
kill $RECEIVER_PID 2>/dev/null || true

BYTES_RECEIVED=0
[ -f /tmp/gw_recv.txt ] && BYTES_RECEIVED=$(wc -c < /tmp/gw_recv.txt)

PPS=$(echo "scale=0; $COUNT / $ACTUAL_DURATION" | bc)
MBPS=$(echo "scale=2; ($BYTES_RECEIVED * 8) / ($ACTUAL_DURATION * 1000000)" | bc)

echo "Results:"
echo "  Packets sent: $COUNT"
echo "  Bytes received: $BYTES_RECEIVED"
echo "  Packets/sec: $PPS"
echo "  Throughput: $MBPS Mbps"

rm -f $PACKET_FILE /tmp/gw_recv.txt

# Test 2: UDP -> Channel Data throughput
echo ""
echo "Test 2: UDP->Channel Throughput (Gateway to Client)"
echo "---------------------------------------------------"

# Create UDP payload
PACKET_FILE=$(mktemp)
dd if=/dev/urandom of=$PACKET_FILE bs=1 count=$PAYLOAD_SIZE 2>/dev/null

# Start receiver
timeout $((DURATION + 2)) nc -u -l -p $CLIENT_PORT > /tmp/client_recv.txt 2>&1 &
RECEIVER_PID=$!
sleep 1

# Send packets for duration
START_TIME=$(date +%s.%N)
END_TIME=$(echo "$START_TIME + $DURATION" | bc)
COUNT=0

echo "Sending UDP packets..."
while (( $(echo "$(date +%s.%N) < $END_TIME" | bc -l) )); do
    for i in {1..100}; do
        cat $PACKET_FILE | nc -u -s $GATEWAY_IP -p $GATEWAY_PORT -w0 $RELAY_IP $ALLOCATION_PORT &
    done
    wait
    COUNT=$((COUNT + 100))
    [ $((COUNT % 1000)) -eq 0 ] && echo "  Sent $COUNT packets"
done

ACTUAL_DURATION=$(echo "$(date +%s.%N) - $START_TIME" | bc)
kill $RECEIVER_PID 2>/dev/null || true

BYTES_RECEIVED=0
[ -f /tmp/client_recv.txt ] && BYTES_RECEIVED=$(wc -c < /tmp/client_recv.txt)

PPS=$(echo "scale=0; $COUNT / $ACTUAL_DURATION" | bc)
MBPS=$(echo "scale=2; ($BYTES_RECEIVED * 8) / ($ACTUAL_DURATION * 1000000)" | bc)

echo "Results:"
echo "  Packets sent: $COUNT"
echo "  Bytes received: $BYTES_RECEIVED" 
echo "  Packets/sec: $PPS"
echo "  Throughput: $MBPS Mbps"

rm -f $PACKET_FILE /tmp/client_recv.txt

echo ""
echo "=== Test Complete ==="#