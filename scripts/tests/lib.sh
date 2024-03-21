#!/usr/bin/env bash

set -euo pipefail

function install_iptables_drop_rules() {
    sudo iptables -I FORWARD 1 -s 172.28.0.100 -d 172.28.0.105 -j DROP
    sudo iptables -I FORWARD 1 -s 172.28.0.105 -d 172.28.0.100 -j DROP
}

function remove_iptables_drop_rules() {
    sudo iptables -D FORWARD -s 172.28.0.100 -d 172.28.0.105 -j DROP
    sudo iptables -D FORWARD -s 172.28.0.105 -d 172.28.0.100 -j DROP
}

function client_curl_resource() {
    docker compose exec -it client curl --max-time 30 --fail -i 172.20.0.100
}

# Downloads a number of bytes from a server (all zeros) and writes them to the given file.
# Parameters:
# $1: Number of bytes
# $2: Max rate
# $3: Destination file
function download_bytes() {
    NUM_BYTES=$1
    RATE=$2
    DESTINATION=$3

    docker compose exec -it client sh -c "curl --fail --limit-rate $RATE http://download.httpbin/bytes?num=$NUM_BYTES" > "$DESTINATION"
}
