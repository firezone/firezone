#!/usr/bin/env bash

source "./scripts/tests/lib.sh"

# 2 seconds are not enough at the given speed to download the file, curl will therefore abort and RST the connection.
client sh -c "curl --max-time 2 --limit-rate 1000000 --no-keepalive --parallel-max 1 --output /dev/null http://download.httpbin/bytes?num=100000000" &
DOWNLOAD_PID=$!

wait $DOWNLOAD_PID || true # The download fails but we want to continue.

sleep 3
readarray -t flows < <(get_flow_logs "tcp")

assert_equals "${#flows[@]}" 1

flow="${flows[0]}"
assert_equals "$(get_flow_field "$flow" "inner_dst_ip")" "172.21.0.101"
assert_greater_than "$(get_flow_field "$flow" "rx_bytes")" 2000000
