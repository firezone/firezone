#!/usr/bin/env bash

# If we set the DNS control to `systemd-resolved` but that's not available,
# we should still boot up and allow IP / CIDR resources to work

set -euo pipefail

source "./scripts/tests/lib.sh"

function client() {
    docker compose exec -it client "$@"
}

function client_nslookup() {
    # Skip the first 3 lines so that grep won't see the DNS server IP
    # `tee` here copies stdout to stderr
    client timeout 30 sh -c "nslookup $1 | tee >(cat 1>&2) | tail -n +4"
}

function gateway() {
    docker compose exec -it gateway "$@"
}

# Re-up the gateway since a local dev setup may run this back-to-back
docker compose up -d gateway --no-build

echo "# make sure resolv.conf was not changed"
client sh -c "cat /etc/resolv.conf"

echo "# Make sure gateway can reach httpbin by DNS"
gateway sh -c "curl --fail dns.httpbin/get"

echo "# Access httpbin by IP"
client_curl_resource

echo "# Stop the gateway and make sure the resource is inaccessible"
docker compose stop gateway
client sh -c "curl --connect-timeout 15 --fail 172.20.0.100/get" && exit 1

# Needed so that the previous failure doesn't bail out of the whole script
exit 0
