#!/usr/bin/env bash

set -e

source "./scripts/tests/lib.sh"

install_iptables_drop_rules
trap remove_iptables_drop_rules EXIT # Cleanup after us

client_curl_resource "172.20.0.100/get"

docker compose restart relay # Restart relay

client_curl_resource "172.20.0.100/get"
