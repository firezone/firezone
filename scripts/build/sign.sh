#!/usr/bin/env bash
set -euo pipefail

if ! command -v AzureSignTool &>/dev/null; then
    echo "AzureSignTool not installed. Signing will be skipped."
    exit
fi

# Forks / dependabot / scheduled runs don't get repository secrets. Skip
# rather than calling AzureSignTool with empty arguments (which logs a
# confusing 401 from Key Vault and then fails the build).
if [[ -z "${AZURE_KEY_VAULT_URI:-}" || -z "${AZURE_CLIENT_ID:-}" || -z "${AZURE_TENANT_ID:-}" || -z "${AZURE_CLIENT_SECRET:-}" || -z "${AZURE_CERT_NAME:-}" ]]; then
    echo "Azure Key Vault env vars not set. Signing will be skipped."
    exit
fi

for exe in "$@"
do
    if [[ ! -f "$exe" ]]; then
        # `register-sparse.exe` and similar helpers may not be in the
        # target dir if they failed to build; surface the gap loudly
        # rather than swallowing it but don't abort the whole signing
        # run.
        echo "sign.sh: skip missing input '$exe'" >&2
        continue
    fi
    AzureSignTool sign \
        --azure-key-vault-url "$AZURE_KEY_VAULT_URI" \
        --azure-key-vault-client-id "$AZURE_CLIENT_ID" \
        --azure-key-vault-tenant-id "$AZURE_TENANT_ID" \
        --azure-key-vault-client-secret "$AZURE_CLIENT_SECRET" \
        --azure-key-vault-certificate "$AZURE_CERT_NAME" \
        --timestamp-rfc3161 "http://timestamp.digicert.com" \
        --verbose "$exe"
done
