#!/usr/bin/env bash

set -e

source "./scripts/tests/lib.sh"

# Establish a channel
client_ping_resource

docker compose stop api # Stop portal

client_ping_resource
