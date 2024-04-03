#!/usr/bin/env bash

set -euo pipefail

source "./scripts/tests/lib.sh"

sleep 61 # Ensure a couple heartbeats have elapsed

client_curl_resource
