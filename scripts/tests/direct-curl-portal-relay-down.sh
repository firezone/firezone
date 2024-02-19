#!/usr/bin/env bash

set -e

source "./scripts/tests/lib.sh"

client_curl_resource # Establish a channel

docker compose stop api # Stop portal

client_curl_resource
