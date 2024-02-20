#!/usr/bin/env bash

set -e

source "./scripts/tests/lib.sh"

client_curl_resource # Establish a connection

docker compose stop api relay # Stop portal & relay

client_curl_resource
