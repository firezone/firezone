#!/usr/bin/env bash

source "./scripts/tests/lib.sh"

# Download 10MB at a max rate of 1MB/s. The first two UDP socket writes will fail as checksum offload is disabled.
# This means it will take 13 seconds + the resent STUN binding request round trip time.
client sh -c \
    "curl \
        --fail \
        --max-time 16 \
        --keepalive-time 1 \
        --limit-rate 1000000 \
        --output download.file \
        http://download.httpbin/bytes?num=10000000" &

DOWNLOAD_PID=$!

sleep 3 # Download a bit

docker network disconnect firezone_client-internal firezone-client-1 # Disconnect the client
sleep 3
docker network connect firezone_client-internal firezone-client-1 --ip 172.30.0.200 --ip6 172:30::200 # Reconnect client with a different IP

# Add static route to internet subnet via router; they get removed when the network interface disappears
client ip -4 route add 203.0.113.0/24 via 172.30.0.254
client ip -6 route add 203:0:113::/64 via 172:30:0::254

# Disable checksum offload again to calculate checksums in software so that checksum verification passes
client ethtool -K eth0 tx off

# Send SIGHUP, triggering `reconnect` internally
sudo kill -s HUP "$(ps -C firezone-headless-client -o pid=)"

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

assert_gteq "${#flows[@]}" 2

declare -A unique_src_tuples
declare -i num_ipv4_tuples

for flow in "${flows[@]}"; do
    # All flows should have same inner_dst_ip
    assert_eq "$(get_flow_field "$flow" "inner_dst_ip")" "172.21.0.101"

    outer_dst_ip=$(get_flow_field "$flow" "outer_dst_ip")
    src_tuple="$(get_flow_field "${flow}" "outer_src_ip") $(get_flow_field "${flow}" "outer_src_port")"

    case $outer_dst_ip in
    "172.31.0.100")
        unique_src_tuples["$src_tuple"]=1
        num_ipv4_tuples+=1
        ;;
    "172:31::100")
        unique_src_tuples["$src_tuple"]=1
        ;;
    *)
        echo "Unexpected 'outer_src_ip': ${outer_dst_ip}"
        exit 1
        ;;
    esac
done

# If we only ever connected via IPv6, two unique source tuples are enough, otherwise we want three.
if [[ $num_ipv4_tuples == 0 ]]; then
    assert_gteq "${#unique_src_tuples[@]}" 2
else
    assert_gteq "${#unique_src_tuples[@]}" 3
fi
