#!/usr/bin/env bash

source "./scripts/tests/lib.sh"

install_iptables_drop_rules

docker compose restart api # Restart portal

client_curl_resource "172.20.0.100/get"

docker compose restart api # Restart again

client_curl_resource "172.20.0.100/get"
