#!/usr/bin/env bash

source "./scripts/tests/lib.sh"

docker compose stop relay-2 # Force Client and Gateway to use the same relay.

for client_ip_family in ipv4 ipv6; do
    for gateway_ip_family in ipv4 ipv6; do
        force_relayed_connections "$client_ip_family" "$gateway_ip_family"

        # Test connectivity
        client_curl_resource "172.20.0.100/get"
        client_curl_resource "[172:20:0::100]/get"

        # Reset for next test case
        docker compose restart client
        docker compose restart gateway

        sleep 2
    done
done
