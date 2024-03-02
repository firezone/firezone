#!/usr/bin/env bash
set -euo pipefail

# Helpful links:
# https://melatonin.dev/blog/how-to-code-sign-windows-installers-with-an-ev-cert-on-github-actions/
# https://learn.microsoft.com/en-us/windows/msix/desktop/cicd-keyvault

# Install the required tools
dotnet tool install --global AzureSignTool

# Sign the MSI file
AzureSignTool sign \
    -kvu "$AZURE_KEY_VAULT_URI" \
    -kvi "$AZURE_CLIENT_ID" \
    -kvt "$AZURE_TENANT_ID" \
    -kvs "$AZURE_CLIENT_SECRET" \
    -kvc "$AZURE_CERT_NAME" \
    -tr http://timestamp.digicert.com \
    -v "$MSI_PATH"
