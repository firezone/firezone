#!/usr/bin/env bash
# Test Linux DNS control using `systemd-resolved` directly inside the CI runner

set -euo pipefail

# TODO: Use DNS and not IP
# HTTPBIN_DNS=172.21.0.100
HTTPBIN_IP=172.20.0.100

# Accessing a resource should fail before the client is up
! curl $HTTPBIN_IP/get && false

resolvectl status
sudo systemctl start firezone-client
sudo systemctl status firezone-client

# Accessing a resource should succeed after the client is up
curl $HTTPBIN_IP/get
