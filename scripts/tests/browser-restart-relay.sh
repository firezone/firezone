#!/usr/bin/env bash

set -euo pipefail

source "./scripts/tests/lib.sh"
HTTPBIN=http://dns.httpbin

install_iptables_drop_rules

start_chromium

docker compose restart relay

echo "# Make sure webpage is loaded once"
load_page $HTTPBIN

echo "# Restart relay"
docker compose restart relay

# Some timeout to get rid of later so that the connection expires
sleep 30

echo "# Reload page"
refresh_page $HTTPBIN
