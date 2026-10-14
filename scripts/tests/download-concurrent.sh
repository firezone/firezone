#!/usr/bin/env bash

source "./scripts/tests/lib.sh"

domains=(download.httpbin alias.httpbin alias2.httpbin)
sizes=(5000000 7000000 9000000)

# Resolve all domains before restricting the port range: the range also applies to
# the UDP sockets used for DNS lookups, so concurrent lookups would race for the
# single available port and the loser fails with "Could not resolve host".
# Only the TCP connections need to share a source port to exercise the Gateway's
# NAT port remapping; `--resolve` below lets curl skip DNS entirely.
ips=()
for domain in "${domains[@]}"; do
    ip="$(client dig +short "$domain" A | head -n 1)"

    if [ -z "$ip" ]; then
        echo "Failed to resolve $domain"
        exit 1
    fi

    ips+=("$ip")
done

client sh -c 'echo "5555 5555" > /proc/sys/net/ipv4/ip_local_port_range'

pids=()
for i in "${!domains[@]}"; do
    client sh -c "curl --fail --max-time 15 --resolve ${domains[$i]}:80:${ips[$i]} --output /tmp/download$i.file http://${domains[$i]}/bytes?num=${sizes[$i]}" &
    pids+=($!)
done

for i in "${!pids[@]}"; do
    wait "${pids[$i]}" || {
        echo "Download via ${domains[$i]} failed"
        exit 1
    }
done

sleep 3
readarray -t flows < <(get_flow_logs "tcp")

assert_eq "${#flows[@]}" 3

for i in "${!domains[@]}"; do
    domain="${domains[$i]}"
    size="${sizes[$i]}"

    found=""
    for flow in "${flows[@]}"; do
        if [ "$(get_flow_field "$flow" "domain")" == "$domain" ]; then
            found="$flow"
            break
        fi
    done

    if [ -z "$found" ]; then
        echo "No flow log found for $domain"
        exit 1
    fi

    rx_bytes="$(get_flow_field "$found" "rx_bytes")"

    assert_eq "$(get_flow_field "$found" "inner_dst_ip")" "172.21.0.101"
    assert_gteq "$rx_bytes" "$size"
    assert_lteq "$rx_bytes" "$((size + 1000000))"
done
