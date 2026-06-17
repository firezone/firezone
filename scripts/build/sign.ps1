$ErrorActionPreference = "Stop"

if (-not (Get-Command AzureSignTool -ErrorAction SilentlyContinue)) {
    Write-Output "AzureSignTool not installed. Signing will be skipped."
    exit 0
}

foreach ($file in $args) {
    $ErrorActionPreference = "Continue"
    $output = & AzureSignTool sign `
        --azure-key-vault-url $env:AZURE_KEY_VAULT_URI `
        --azure-key-vault-client-id $env:AZURE_CLIENT_ID `
        --azure-key-vault-tenant-id $env:AZURE_TENANT_ID `
        --azure-key-vault-client-secret $env:AZURE_CLIENT_SECRET `
        --azure-key-vault-certificate $env:AZURE_CERT_NAME `
        --timestamp-rfc3161 "http://timestamp.digicert.com" `
        --verbose $file 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = "Stop"
    Write-Output ($output | Out-String)
    if ($code -ne 0) {
        throw "AzureSignTool failed for $file (exit code $code)"
    }
    $signature = Get-AuthenticodeSignature -FilePath $file
    if ($signature.Status -ne "Valid") {
        throw "Authenticode verification failed for ${file}: $($signature.Status) - $($signature.StatusMessage)"
    }
}

exit 0
