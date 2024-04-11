#!/usr/bin/env bash

source "./scripts/tests/lib.sh"

install_iptables_drop_rules

client_curl_resource "172.20.0.100/get"

# Restart relay with new IP
PUBLIC_IP4_ADDR="172.28.0.102" docker compose up -d relay

client_curl_resource "172.20.0.100/get"
