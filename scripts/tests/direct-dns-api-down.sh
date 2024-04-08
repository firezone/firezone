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

run_test

docker compose stop api

run_test
