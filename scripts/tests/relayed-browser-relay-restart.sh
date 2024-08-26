#!/usr/bin/env bash

source "./scripts/tests/lib.sh"
HTTPBIN=http://dns.httpbin

docker compose stop relay-2

install_iptables_drop_rules
bootstrap_browser_test_harness

echo "# Make sure webpage is loaded once"
load_page $HTTPBIN 1

echo "# Simulate rolling deployment of relays"
docker compose start relay-2
docker compose kill relay-1 --signal SIGTERM

sleep 1

echo "# Load page again"
load_page $HTTPBIN 10
