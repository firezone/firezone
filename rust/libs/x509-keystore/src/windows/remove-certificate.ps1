<#
.SYNOPSIS
    Removes a certificate and its private key from the CurrentUser\My store.
#>

param(
    # The certificate provider ignores `-LiteralPath`, so only a thumbprint free of wildcards and
    # path separators addresses exactly one certificate.
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9A-Fa-f]+$')]
    [string]$Thumbprint
)

$ErrorActionPreference = 'Stop'

Remove-Item -Path "Cert:\CurrentUser\My\$Thumbprint" -DeleteKey -Confirm:$false
