#!/usr/bin/env bash

source "./scripts/tests/lib.sh"

# 2 seconds are not enough at the given speed to download the file, curl will therefore abort and RST the connection.
client sh -c "curl --max-time 2 --limit-rate 1000000 --no-keepalive --parallel-max 1 --output /dev/null http://download.httpbin/bytes?num=100000000" &
DOWNLOAD_PID=$!

wait $DOWNLOAD_PID || true # The download fails but we want to continue.

sleep 3
readarray -t flows < <(get_flow_logs "tcp")

assert_gteq "${#flows[@]}" 1

rx_bytes=0

# All flows should have same inner_dst_ip
for flow in "${flows[@]}"; do
    assert_eq "$(get_flow_field "$flow" "inner_dst_ip")" "172.21.0.101"
    rx_bytes+="$(get_flow_field "$flow" "rx_bytes")"
done

assert_gteq "$rx_bytes" 2000000
