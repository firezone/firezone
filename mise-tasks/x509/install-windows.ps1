#!/usr/bin/env pwsh
#MISE description="Import the test X.509 client certificate into the Windows certificate store"
#USAGE flag "--alias <alias>" help="Name `//:x509:gen-certificate` stored the key under [default: firezone-client]"
#USAGE flag "--password <password>" help="PKCS#12 export password [default: firezone]"

$ErrorActionPreference = 'Stop'

# `$IsWindows` does not exist in Windows PowerShell, where the edition is the answer instead.
$onWindows = $IsWindows -or ($PSVersionTable.PSEdition -eq 'Desktop')

# One task per platform, so running the wrong one is a mistake worth naming rather than a
# confusing failure further down.
if (-not $onWindows) {
    [Console]::Error.WriteLine(
        "error: this task installs into a Windows certificate store, but this is $([Environment]::OSVersion.Platform).")
    [Console]::Error.WriteLine("'mise tasks' lists the task for this platform.")

    exit 1
}

# Defaults matching the ones `//:x509:gen-certificate` writes with.
$certAlias = if ($env:usage_alias) { $env:usage_alias } else { 'firezone-client' }
$p12Password = if ($env:usage_password) { $env:usage_password } else { 'firezone' }
$cacheHome = if ($env:XDG_CACHE_HOME) { $env:XDG_CACHE_HOME } else { Join-Path $HOME '.cache' }
$p12Path = Join-Path $cacheHome "firezone\x509\$certAlias.p12"

if (-not (Test-Path -LiteralPath $p12Path -PathType Leaf)) {
    [Console]::Error.WriteLine("error: $p12Path does not exist; run 'mise run //:x509:gen-certificate' first")

    exit 1
}

# `Import-PfxCertificate` comes from the PKI module, which ships with Windows PowerShell.
# Microsoft lists PKI as untested with PowerShell 7's Windows PowerShell compatibility layer,
# so run this under `powershell.exe` if PowerShell 7 cannot produce the cmdlet.
if (-not (Get-Command Import-PfxCertificate -ErrorAction SilentlyContinue)) {
    [Console]::Error.WriteLine('error: Import-PfxCertificate is unavailable, so the PKI module did not load.')
    [Console]::Error.WriteLine("Run this task under Windows PowerShell: powershell.exe -NoProfile -File $PSCommandPath")

    exit 1
}

Write-Output "==> Importing $p12Path into Cert:\CurrentUser\My..."

$password = ConvertTo-SecureString -String $p12Password -AsPlainText -Force
$imported = @(Import-PfxCertificate -FilePath $p12Path -CertStoreLocation 'Cert:\CurrentUser\My' -Password $password)

# The file carries the issuing CA alongside the client certificate, and both land in the store.
$certificate = $imported | Where-Object { $_.HasPrivateKey } | Select-Object -First 1

if (-not $certificate) {
    throw 'No certificate with a private key was imported.'
}

Write-Output ('Imported ' + $certificate.Subject)
Write-Output ('Thumbprint ' + $certificate.Thumbprint)

# The Client signs through CNG and cannot use a key held by a legacy cryptographic service
# provider, which is where PFXImportCertStore puts an RSA key that names no provider of its own.
$provider = certutil -user -store My $certificate.Thumbprint |
    Select-String -Pattern 'Provider =' |
    Select-Object -First 1

if ($provider) {
    Write-Output $provider.Line.Trim()
}

if (-not $provider -or $provider.Line -notmatch 'Key Storage Provider') {
    Write-Warning 'The private key is not held by a CNG key storage provider, so the Client cannot sign with it.'
    Write-Warning 'Delete it from Cert:\CurrentUser\My and import it again with certutil instead:'
    Write-Warning ('  certutil -f -user -p ' + $p12Password + ' -csp "Microsoft Software Key Storage Provider" -importpfx My ' + $p12Path)
}

Write-Output ''
Write-Output "'firezone-client-tunnel.exe x509' prints what the Client makes of the store."
Write-Output ''
Write-Output 'That store belongs to your account. The installed Tunnel service runs as LocalSystem and'
Write-Output 'will not see it; give the service its own copy from an elevated PowerShell:'
Write-Output ''
Write-Output ("    Import-PfxCertificate -FilePath '$p12Path' -CertStoreLocation Cert:\LocalMachine\My -Password (ConvertTo-SecureString -String '$p12Password' -AsPlainText -Force)")
