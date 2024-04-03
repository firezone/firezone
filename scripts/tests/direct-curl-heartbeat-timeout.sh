#!/usr/bin/env bash

set -euo pipefail

source "./scripts/tests/lib.sh"

client_curl_resource

sleep 61 # Ensure a couple heartbeats have elapsed

client_curl_resource
