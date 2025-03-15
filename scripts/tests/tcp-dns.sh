#!/usr/bin/env bash

source "./scripts/tests/lib.sh"

client sh -c "apk add bind-tools" # The compat tests run using the production image which doesn't have `dig`.

echo "Resolving DNS resource over TCP with search domain"
client sh -c "dig +search +tcp dns"

echo "Resolving DNS resource over TCP with FQDN"
client sh -c "dig +tcp download.httpbin"

echo "Resolving non-DNS resource over TCP"
client sh -c "dig +tcp example.com"

echo "Testing TCP fallback"
client sh -c "dig 2048.size.dns.netmeister.org"
