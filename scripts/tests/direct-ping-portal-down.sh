#!/usr/bin/env bash

set -e

source "./scripts/tests/lib.sh"

client_ping_gateway

docker compose stop api relay # Stop portal & relay

sleep 5 # Wait for client to disconnect

client_ping_gateway
