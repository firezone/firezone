#!/usr/bin/env bash

source "./scripts/tests/lib.sh"
HTTPBIN=http://dns.httpbin

install_iptables_drop_rules
start_chromium

echo "# Make sure webpage is loaded once"
load_page $HTTPBIN

echo "# Restart relay"
docker compose restart relay

echo "# Reload page"
timeout 60 sh -c "until refresh_page $HTTPBIN &>/dev/null; do sleep 10; done"
