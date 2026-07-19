#!/usr/bin/env bash

source "./scripts/tests/lib.sh"

# Bound the connect phase, then abort only if the transfer stalls (speed stays
# below 100 KiB/s for 10s) rather than on a fixed deadline: a slow-but-progressing
# download on a busy runner is fine, a hung tunnel is not.
client sh -c "curl --fail --connect-timeout 10 --speed-limit 102400 --speed-time 10 --output download.file http://download.httpbin/bytes?num=10000000" &

DOWNLOAD_PID=$!

wait $DOWNLOAD_PID || {
    echo "Download process failed"
    exit 1
}

known_checksum="f5e02aa71e67f41d79023a128ca35bad86cf7b6656967bfe0884b3a3c4325eaf"
computed_checksum=$(client sha256sum download.file | awk '{ print $1 }')

if [[ "$computed_checksum" != "$known_checksum" ]]; then
    echo "Checksum of downloaded file does not match"
    exit 1
fi

sleep 3
readarray -t flows < <(get_flow_logs "tcp")

assert_eq "${#flows[@]}" 1

flow="${flows[0]}"
assert_eq "$(get_flow_field "$flow" "inner_dst_ip")" "172.21.0.101"
assert_eq "$(get_flow_field "$flow" "domain")" "download.httpbin"
assert_gteq "$(get_flow_field "$flow" "rx_bytes")" 10000000
