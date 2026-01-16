#!/usr/bin/env bash

# The integration tests call this to test Linux DNS control, using the `/etc/resolv.conf`
# method which only works well inside Alpine Docker containers.

source "./scripts/tests/lib.sh"

HTTPBIN=dns
HTTPBIN_FQDN="$HTTPBIN.httpbin.search.test"

# Re-up the gateway since a local dev setup may run this back-to-back
docker compose up -d gateway --no-build

echo "# check original resolv.conf"
client sh -c "cat /etc/resolv.conf.before-firezone"

echo "# Make sure gateway can reach httpbin by DNS"
gateway sh -c "curl --fail $HTTPBIN_FQDN/get"

echo "# Try to ping httpbin as a DNS resource"
client_ping_resource "$HTTPBIN"

echo "# Access httpbin by DNS"
client_curl_resource "$HTTPBIN/get"

echo "# Make sure it's going through the tunnel"
client_nslookup "$HTTPBIN" | grep "19\\.0\\.0\\."

echo "# Make sure a non-resource doesn't go through the tunnel"
(client_nslookup "github.com" | grep "19\\.0\\.0\\.") && exit 1

echo "# Stop the gateway and make sure the resource is inaccessible"
docker compose stop gateway
client_curl_resource "$HTTPBIN/get" && exit 1

exit 0
