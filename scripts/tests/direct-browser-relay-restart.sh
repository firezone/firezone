#!/usr/bin/env bash

source "./scripts/tests/lib.sh"
HTTPBIN=http://dns.httpbin

docker compose stop relay-2

bootstrap_browser_test_harness
start_chromium

echo "# Make sure webpage is loaded once"
load_page $HTTPBIN 1

echo "# Simulate rolling deployment of relays"
docker compose start relay-2
docker compose kill relay-1 --signal SIGTERM

sleep 1

echo "# Reload page"
refresh_page $HTTPBIN 10
