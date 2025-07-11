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

docker compose stop api

run_test
