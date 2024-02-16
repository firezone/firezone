#!/usr/bin/env bash

set -e

source "./scripts/tests/lib.sh"

install_iptables_drop_rules
trap remove_iptables_drop_rules EXIT # Cleanup after us

docker compose stop relay # Restart relay

sleep 5 # Wait for relay to restart

client_ping_resource
