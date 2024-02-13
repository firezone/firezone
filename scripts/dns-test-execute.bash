#!/usr/bin/env bash

set -euo pipefail

HTTPBIN=test.httpbin.docker.local

# Wait for client to ping httpbin (CIDR) resource through the gateway
docker compose exec -it client timeout 60 \
sh -c "until ping -W 1 -c 10 172.20.0.100 &>/dev/null; do true; done"

# check original resolv.conf
docker compose exec -it client sh -c "cat /etc/resolv.conf.firezone-backup"

# Make sure gateway can reach httpbin by DNS
docker compose exec -it gateway sh -c "curl $HTTPBIN/get || true"

# Try to ping httpbin as a DNS resource
docker compose exec -it client timeout 60 \
sh -c "ping -W 1 -c 10 $HTTPBIN"

# Access httpbin by DNS
docker compose exec -it client sh -c "curl $HTTPBIN/get || true"

# Make sure it's going through the tunnel
docker compose exec -it client timeout 60 \
sh -c "nslookup $HTTPBIN; nslookup $HTTPBIN | tail -n +4 | grep 100\\.96\\.0\\."

# Make sure a non-resource doesn't go through the tunnel
docker compose exec -it client timeout 60 \
sh -c "nslookup github.com; nslookup github.com | tail -n +4 | grep -v 100\\.96.\\0\\."
