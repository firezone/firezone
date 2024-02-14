#!/usr/bin/env bash

set -e

source "./lib.sh"

client_ping_gateway();

docker compose stop api relay # Stop relay & relay

sleep 5 # Wait for client to disconnect

client_ping_gateway();
