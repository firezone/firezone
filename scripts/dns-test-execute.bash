#!/usr/bin/env bash

# The integration tests call this to test Linux DNS control, using the `/etc/resolv.conf`
# method which only works well inside Alpine Docker containers.

set -euo pipefail

HTTPBIN=test.httpbin.docker.local

# Wait for client to ping httpbin (CIDR) resource through the gateway
docker compose exec -it client timeout 60 \
sh -c "until ping -W 1 -c 10 172.20.0.100 &>/dev/null; do true; done"

echo "# check original resolv.conf"
docker compose exec -it client sh -c "cat /etc/resolv.conf.firezone-backup"

echo "# Make sure gateway can reach httpbin by DNS"
docker compose exec -it gateway sh -c "curl $HTTPBIN/get"

echo "# Try to ping httpbin as a DNS resource"
docker compose exec -it client timeout 60 \
sh -c "ping -W 1 -c 10 $HTTPBIN"

echo "# Access httpbin by DNS"
docker compose exec -it client sh -c "curl $HTTPBIN/get"

echo "# Make sure it's going through the tunnel"
docker compose exec -it client timeout 60 \
sh -c "nslookup $HTTPBIN; nslookup $HTTPBIN | tail -n +4 | grep 100\\.96\\.0\\."

echo "# Make sure a non-resource doesn't go through the tunnel"
docker compose exec -it client timeout 60 \
sh -c "nslookup github.com; nslookup github.com | tail -n +4 | grep -v 100\\.96.\\0\\."

echo "# Stop the gateway and make sure the resource is inaccessible"
docker compose stop gateway
docker compose exec -it client timeout 15 \
sh -c "curl $HTTPBIN/get" && exit 1
