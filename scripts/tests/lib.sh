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
    trap remove_iptables_drop_rules EXIT # Cleanup after us
}

function remove_iptables_drop_rules() {
    sudo iptables -D FORWARD -s 172.28.0.100 -d 172.28.0.105 -j DROP
    sudo iptables -D FORWARD -s 172.28.0.105 -d 172.28.0.100 -j DROP
}

function client_curl_resource() {
    client curl --fail "$1"
}

function client_ping_resource() {
    client timeout 30 \
        sh -c "until ping -W 1 -c 1 $1 &>/dev/null; do true; done"
}

function client_nslookup() {
    # Skip the first 3 lines so that grep won't see the DNS server IP
    # `tee` here copies stdout to stderr
    client timeout 30 sh -c "nslookup $1 | tee >(cat 1>&2) | tail -n +4"
}
