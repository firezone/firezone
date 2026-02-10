#!/usr/bin/env bash

# The integration tests call this to test Linux DNS control, using the `/etc/resolv.conf`
# method which only works well inside Alpine Docker containers.

source "./scripts/tests/lib.sh"

RESOURCE1=dns
RESOURCE2=download.httpbin

echo "# Try to ping httpbin as DNS resource 1"
client_ping "$RESOURCE1"

echo "# Try to ping httpbin as DNS resource 2"
client_ping "$RESOURCE2"
