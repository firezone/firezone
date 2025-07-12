#!/usr/bin/env bash

source "./scripts/tests/lib.sh"

HTTPBIN=dns.httpbin.search.test

function run_test() {
    echo "# Access httpbin by DNS"
    client_curl_resource "$HTTPBIN/get"

    echo "# Make sure it's going through the tunnel"
    client_nslookup "$HTTPBIN" | grep "100\\.96\\.0\\."
}

install_iptables_drop_rules

run_test

# Restart relays with new IP
RELAY_1_PUBLIC_IP4_ADDR="172.28.0.102" docker compose up -d relay-1
RELAY_2_PUBLIC_IP4_ADDR="172.28.0.202" docker compose up -d relay-2

run_test
