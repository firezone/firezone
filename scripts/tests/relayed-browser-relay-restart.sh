#!/usr/bin/env bash

source "./scripts/tests/lib.sh"
HTTPBIN=http://dns.httpbin

install_iptables_drop_rules
start_chromium

echo "# Make sure webpage is loaded once"
load_page $HTTPBIN 1

echo "# Restart relay"
docker compose restart relay

echo "# Reload page"
refresh_page $HTTPBIN 10
