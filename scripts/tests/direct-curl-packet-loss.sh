#!/usr/bin/env bash

source "./scripts/tests/lib.sh"

client apk add --no-cache iproute2
client tc qdisc add dev eth0 root netem loss 20%

client_curl_resource "172.20.0.100/get"
