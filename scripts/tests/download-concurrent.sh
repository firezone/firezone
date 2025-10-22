#!/usr/bin/env bash

source "./scripts/tests/lib.sh"

client sh -c "curl --fail --max-time 10 --output /tmp/download1.file http://download.httpbin/bytes?num=5000000" &
PID1=$!

client sh -c "curl --fail --max-time 10 --output /tmp/download2.file http://download.httpbin/bytes?num=5000000" &
PID2=$!

client sh -c "curl --fail --max-time 10 --output /tmp/download3.file http://download.httpbin/bytes?num=5000000" &
PID3=$!

wait $PID1 || {
    echo "Download 1 failed"
    exit 1
}

wait $PID2 || {
    echo "Download 2 failed"
    exit 1
}

wait $PID3 || {
    echo "Download 3 failed"
    exit 1
}

sleep 3
readarray -t flows < <(get_flow_logs "tcp")

assert_eq "${#flows[@]}" 3

for flow in "${flows[@]}"; do
    assert_eq "$(get_flow_field "$flow" "inner_dst_ip")" "172.21.0.101"
    assert_gteq "$(get_flow_field "$flow" "rx_bytes")" 5000000
done
