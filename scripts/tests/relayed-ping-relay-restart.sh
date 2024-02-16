#!/usr/bin/env bash

set -e

source "./scripts/tests/lib.sh"

install_iptables_drop_rules
trap remove_iptables_drop_rules EXIT # Cleanup after us

# Don't establish a channel first
# client_ping_resource

docker compose stop relay # Restart relay

sleep 5 # Wait for relay to restart

client_ping_resource
