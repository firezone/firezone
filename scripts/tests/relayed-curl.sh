#!/usr/bin/env bash

source "./scripts/tests/lib.sh"

install_iptables_drop_rules

client_curl_resource "172.20.0.100/get"
