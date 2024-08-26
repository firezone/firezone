#!/usr/bin/env bash

source "./scripts/tests/lib.sh"
HTTPBIN=http://dns.httpbin

docker compose stop relay-2

echo "# Load page"
client_curl_resource $HTTPBIN/get

echo "# Simulate rolling deployment of relays"
docker compose start relay-2
docker compose kill relay-1 --signal SIGTERM

sleep 1

echo "# Load page again"
client_curl_resource $HTTPBIN/get
