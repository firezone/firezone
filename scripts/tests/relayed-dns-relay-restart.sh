#!/usr/bin/env bash

set -euo pipefail

source "./scripts/tests/lib.sh"

HTTPBIN=dns.httpbin

function run_test() {
    echo "# Access httpbin by DNS"
    client_curl_resource "$HTTPBIN/get"

    echo "# Make sure it's going through the tunnel"
    client_nslookup "$HTTPBIN" | grep "100\\.96\\.0\\."
}

install_iptables_drop_rules

run_test

# Restart relay with new IP
PUBLIC_IP4_ADDR="172.28.0.102" docker compose up -d relay

run_test
