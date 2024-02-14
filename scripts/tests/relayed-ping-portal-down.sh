#!/usr/bin/env bash

set -e

install_iptables_drop_rules();
trap remove_iptables_drop_rules EXIT # Cleanup after us

client_ping_gateway();

docker compose stop api # Stop portal

sleep 5 # Wait for client to disconnect

client_ping_gateway();
