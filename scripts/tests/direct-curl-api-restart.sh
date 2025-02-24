#!/usr/bin/env bash

source "./scripts/tests/lib.sh"

docker compose restart api # Restart portal

# Give the client time to reconnect
sleep 3

client_curl_resource "172.20.0.100/get"

docker compose restart api # Restart again

# Give the client time to reconnect
sleep 3

client_curl_resource "172.20.0.100/get"
