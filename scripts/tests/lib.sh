#!/usr/bin/env bash

function client() {
    docker compose exec -it client "$@"
}

function gateway() {
    docker compose exec -it gateway "$@"
}

function install_iptables_drop_rules() {
    sudo iptables -I FORWARD 1 -s 172.28.0.100 -d 172.28.0.105 -j DROP
    sudo iptables -I FORWARD 1 -s 172.28.0.105 -d 172.28.0.100 -j DROP
}

function remove_iptables_drop_rules() {
    sudo iptables -D FORWARD -s 172.28.0.100 -d 172.28.0.105 -j DROP
    sudo iptables -D FORWARD -s 172.28.0.105 -d 172.28.0.100 -j DROP
}

function client_curl_resource() {
    # More than 5 seconds on the same host means we have a bug.
    client curl --fail "$1"
}

function client_nslookup() {
    # Skip the first 3 lines so that grep won't see the DNS server IP
    # `tee` here copies stdout to stderr
    client timeout 30 sh -c "nslookup $1 | tee >(cat 1>&2) | tail -n +4"
}
