#!/usr/bin/env bash

set -euo pipefail

source "./scripts/tests/lib.sh"

install_iptables_drop_rules
trap remove_iptables_drop_rules EXIT # Cleanup after us

sleep 61 # Ensure a couple heartbeats have elapsed

client_curl_resource
