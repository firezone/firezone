#!/usr/bin/env bash

set -e

source "./lib.sh"

client_ping_gateway();

docker compose stop api # Stop portal

sleep 5 # Wait for client to disconnect

client_ping_gateway();
