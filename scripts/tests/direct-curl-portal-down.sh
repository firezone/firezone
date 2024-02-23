#!/usr/bin/env bash

set -euo pipefail

source "./scripts/tests/lib.sh"

client_curl_resource # Establish a connection

docker compose stop api relay # Stop portal & relay

client_curl_resource
