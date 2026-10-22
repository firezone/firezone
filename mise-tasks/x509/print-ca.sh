#!/usr/bin/env bash
#MISE description="Print the test CA certificate, to paste into the portal's trust anchors"
set -euo pipefail

ca_crt="${XDG_CACHE_HOME:-${HOME}/.cache}/firezone/x509/ca.crt"

if [ ! -f "$ca_crt" ]; then
    echo "error: ${ca_crt} does not exist; run 'mise run //:x509:create-ca' first" >&2
    exit 1
fi

# Only the PEM goes to stdout, so this can be piped straight into a clipboard.
cat "$ca_crt"
