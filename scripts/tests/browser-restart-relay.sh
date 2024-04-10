#!/usr/bin/env bash

set -euo pipefail

source "./scripts/tests/lib.sh"

install_iptables_drop_rules

start_chromium

docker compose restart relay

echo "# Make sure webpage is loaded once"
load_page

echo "# Restart relay"
docker compose restart relay

# Some timeout to get rid of later so that the connection expires
sleep 30

echo "# Reload page"
refresh_page


refresh_page

run_test
