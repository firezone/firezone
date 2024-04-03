#!/usr/bin/env bash

set -euo pipefail

source "./scripts/tests/lib.sh"

sleep 70 # Ensure a couple heartbeats have allegedly elapsed

client_curl_resource
