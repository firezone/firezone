#!/usr/bin/env bash

set -euo pipefail

source "./scripts/tests/lib.sh"

install_iptables_drop_rules
trap remove_iptables_drop_rules EXIT # Cleanup after us

docker compose restart api # Restart portal

client_curl_resource "172.20.0.100/get"

docker compose restart api # Restart again

client_curl_resource "172.20.0.100/get"
