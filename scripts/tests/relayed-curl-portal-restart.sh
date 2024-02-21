#!/usr/bin/env bash

set -euo pipefail

source "./scripts/tests/lib.sh"

install_iptables_drop_rules
trap remove_iptables_drop_rules EXIT # Cleanup after us

client_curl_resource

docker compose restart api # Restart portal

sleep 5 # Wait for client to reconnect

client_curl_resource
