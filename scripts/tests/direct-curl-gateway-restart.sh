#!/usr/bin/env bash

source "./scripts/tests/lib.sh"

client_curl "172.20.0.100/get"
client_curl "[172:20:0::100]/get"

docker compose restart gateway

client_curl "172.20.0.100/get"
client_curl "[172:20:0::100]/get"
