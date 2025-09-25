#!/usr/bin/env bash

source "./scripts/tests/lib.sh"

client_curl_resource "172.20.0.100/get"
client_curl_resource "[172:20:0::100]/get"

api_send_reject_access "mycro-aws-gws" "MyCorp Network"        # This is the 172.20.0.1/16 network
api_send_reject_access "mycro-aws-gws" "MyCorp Network (IPv6)" # This is the 172:20:0::1/64 network

client_curl_resource "172.20.0.100/get"
client_curl_resource "[172:20:0::100]/get"
