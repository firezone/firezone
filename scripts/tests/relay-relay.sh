#!/usr/bin/env bash

source "./scripts/tests/lib.sh"

docker compose stop relay-2 # Force Client and Gateway to use the same relay.

for container in client gateway; do
    # Drop all outgoing traffic
    docker compose exec -T "$container" iptables -P OUTPUT DROP
    # Only allow traffic to the relay control port (forces relay-relay candidate)
    docker compose exec -T "$container" iptables -A OUTPUT -p udp --dport 3478 -j ACCEPT

    # Test connectivity
    client_curl_resource "172.20.0.100/get"
    client_curl_resource "[172:20:0::100]/get"

    # Reset for next test case
    docker compose restart client
    docker compose restart gateway

    # Flush all rules back to the default
    docker compose exec -T "$container" iptables -F

    sleep 2
done
