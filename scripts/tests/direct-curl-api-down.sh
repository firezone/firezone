#!/usr/bin/env bash

set -euo pipefail

source "./scripts/tests/lib.sh"

client_curl_resource "172.20.0.100/get"

docker compose stop api # Stop portal

client_curl_resource "172.20.0.100/get"
