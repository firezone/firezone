#!/usr/bin/env bash

set -e

source "./scripts/tests/lib.sh"

docker compose restart api # Restart portal

client_curl_resource
