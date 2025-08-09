#!/usr/bin/env bash

source "./scripts/tests/lib.sh"

client sysctl -w net.ipv4.tcp_ecn=1
client sysctl -w net.ipv6.tcp_ecn=1

client_curl_resource "172.20.0.100/get"
client_curl_resource "[172:20:0::100]/get"
