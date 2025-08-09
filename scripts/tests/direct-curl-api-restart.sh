#!/usr/bin/env bash

source "./scripts/tests/lib.sh"

docker compose restart api # Restart portal

client_curl_resource "172.20.0.100/get"
client_curl_resource "172:20:0::100/get"

docker compose restart api # Restart again

client_curl_resource "172.20.0.100/get"
client_curl_resource "172:20:0::100/get"
