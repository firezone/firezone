#!/usr/bin/env bash

source "./scripts/tests/lib.sh"

# Authorize resource 1
client_curl "172.20.0.100/get"
client_curl "[172:20:0::100]/get"

# Authorize resource 2 (important, otherwise the Gateway will close the connection on the last resource being removed)
client_ping download.httpbin

# Revoke access to resource 1
portal_send_reject_access "mycro-aws-gws" "MyCorp Network"        # This is the 172.20.0.1/16 network
portal_send_reject_access "mycro-aws-gws" "MyCorp Network (IPv6)" # This is the 172:20:0::1/64 network

# Try to access resource 1 again
# First one for each IP will fail because we get an ICMP error.
expect_error client_curl_resource "172.20.0.100/get"
expect_error client_curl_resource "[172:20:0::100]/get"

client_curl "172.20.0.100/get"
client_curl "[172:20:0::100]/get"
