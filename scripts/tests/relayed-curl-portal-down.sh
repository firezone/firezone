#!/usr/bin/env bash

set -e

source "./scripts/tests/lib.sh"

install_iptables_drop_rules
trap remove_iptables_drop_rules EXIT # Cleanup after us

client_curl_resource

docker compose stop api # Stop portal

sleep 5 # Wait for client to disconnect

client_curl_resource
