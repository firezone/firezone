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
        --azure-key-vault-client-id "$AZURE_CLIENT_ID" \
        --azure-key-vault-tenant-id "$AZURE_TENANT_ID" \
        --azure-key-vault-client-secret "$AZURE_CLIENT_SECRET" \
        --azure-key-vault-certificate "$AZURE_CERT_NAME" \
        --timestamp-rfc3161 "http://timestamp.digicert.com" \
        --verbose "$exe"
done
