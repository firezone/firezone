#!/usr/bin/env bash

source "./scripts/tests/lib.sh"

install_iptables_drop_rules

client_curl_resource "172.20.0.100/get"

# Restart relays with new IPs
RELAY_1_PUBLIC_IP4_ADDR="172.28.0.102" docker compose up -d relay-1
RELAY_2_PUBLIC_IP4_ADDR="172.28.0.202" docker compose up -d relay-2

client_curl_resource "172.20.0.100/get"
