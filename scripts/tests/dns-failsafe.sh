#!/usr/bin/env bash

# If we set the DNS control to `systemd-resolved` but that's not available,
# we should still boot up and allow IP / CIDR resources to work

source "./scripts/tests/lib.sh"

# Re-up the gateway since a local dev setup may run this back-to-back
docker compose up -d gateway --no-build

echo "# make sure resolv.conf was not changed"
client sh -c "cat /etc/resolv.conf"

echo "# Make sure gateway can reach httpbin by DNS"
gateway sh -c "curl --fail dns.httpbin/get"

echo "# Access httpbin by IP"
client_curl_resource "172.20.0.100/get"

echo "# Stop the gateway and make sure the resource is inaccessible"
docker compose stop gateway
client_curl_resource "172.20.0.100/get" && exit 1

# Needed so that the previous failure doesn't bail out of the whole script
exit 0
