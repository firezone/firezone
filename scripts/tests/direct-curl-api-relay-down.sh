#!/usr/bin/env bash

source "./scripts/tests/lib.sh"

client_curl_resource "172.20.0.100/get"

docker compose stop api relay-1 relay-2 # Stop portal & relays

client_curl_resource "172.20.0.100/get"
