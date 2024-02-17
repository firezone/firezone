#!/usr/bin/env bash

set -e

source "./scripts/tests/lib.sh"

client_curl_resource

docker compose restart api # Restart portal

sleep 5 # Wait for client to reconnect

client_curl_resource
