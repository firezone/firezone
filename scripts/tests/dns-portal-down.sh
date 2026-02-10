#!/usr/bin/env bash

source "./scripts/tests/lib.sh"

HTTPBIN=dns

function run_test() {
    echo "# Access httpbin by DNS"
    client_curl "$HTTPBIN/get"

    echo "# Make sure it's going through the tunnel"
    client_nslookup "$HTTPBIN" | grep "100\\.96\\.0\\."
}

run_test

docker compose stop portal

run_test
