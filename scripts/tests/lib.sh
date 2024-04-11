#!/usr/bin/env bash

set -euox pipefail

function client() {
    docker compose exec -it client "$@"
}

function start_chromium() {
    docker compose exec -d -it client chromium-browser --headless --no-sandbox --remote-debugging-port=$CHROMIUM_PORT
}

function load_page() {
    client npm run load -- --debugPort $CHROMIUM_PORT --url "$@"
}

function refresh_page() {
    client npm run refresh -- --debugPort $CHROMIUM_PORT --url "$@"
}

function gateway() {
    docker compose exec -it gateway "$@"
}

function relay() {
    docker compose exec -it relay "$@"
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
    client curl --fail "$1" > /dev/null
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

function assert_equals() {
    local expected="$1"
    local actual="$2"

    if [[ "$expected" != "$actual" ]]; then
        echo "Expected $expected but got $actual"
        exit 1
    fi
}

function process_state() {
    local process_name="$1"

    ps -C "$process_name" -o state=
}

function assert_process_state {
    local process_name="$1"
    local expected_state="$2"

    assert_equals "$(process_state "$process_name")" "$expected_state"
}
