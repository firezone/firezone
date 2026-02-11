#!/usr/bin/env bash

source "./scripts/tests/lib.sh"

client sysctl -w net.ipv4.tcp_ecn=1

client_curl "172.20.0.100/get"
client_curl "[172:20:0::100]/get"
