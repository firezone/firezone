#!/usr/bin/env bash

set -euo pipefail

source "./scripts/tests/lib.sh"

docker compose restart api # Restart portal

client_curl_resource

docker compose restart api # Restart again

client_curl_resource
