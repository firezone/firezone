#!/usr/bin/env bash

set -e

source "./scripts/tests/lib.sh"

install_iptables_drop_rules
trap remove_iptables_drop_rules EXIT # Cleanup after us

# Establish a connection to the relay
client_ping_resource

docker compose stop api # Stop portal

client_ping_resource
