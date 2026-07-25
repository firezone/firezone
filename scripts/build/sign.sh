#!/usr/bin/env bash
set -euo pipefail

if ! command -v AzureSignTool &>/dev/null; then
    echo "AzureSignTool not installed. Signing will be skipped."
    exit
fi

for exe in "$@"
do
    AzureSignTool sign \
        --azure-key-vault-url "$AZURE_KEY_VAULT_URI" \
        --azure-key-vault-managed-identity \
        --azure-key-vault-certificate "$AZURE_CERT_NAME" \
        --timestamp-rfc3161 "http://timestamp.digicert.com" \
        --verbose "$exe"
done
