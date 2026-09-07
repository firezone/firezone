#!/usr/bin/env pwsh
#MISE description="Remove the test X.509 client certificate from the Windows certificate store"

$ErrorActionPreference = 'Stop'

# `$IsWindows` does not exist in Windows PowerShell, where the edition is the answer instead.
$onWindows = $IsWindows -or ($PSVersionTable.PSEdition -eq 'Desktop')

# One task per platform, so running the wrong one is a mistake worth naming rather than a
# confusing failure further down.
if (-not $onWindows) {
    [Console]::Error.WriteLine(
        "error: this task removes from a Windows certificate store, but this is $([Environment]::OSVersion.Platform).")
    [Console]::Error.WriteLine("'mise tasks' lists the task for this platform.")

    exit 1
}

# `//:x509:gen-certificate` issues the certificate under this common name, which is how the
# Client finds it and how this task narrows the store down. A real deployment's certificates
# carry it too, so only the CA a certificate chains to makes it this task's to delete, and
# nothing here falls back to the name: leaving one of ours behind costs a line of output,
# deleting an MDM's costs a machine its identity.
#
# The CA the certificate was issued from has its own tasks and its own lifetime, so it stays
# where it is even though `//:x509:install-windows` carries it into the store alongside this
# certificate.
$commonName = 'dev.firezone.device-trust'

# Resolved the way `//:x509:install-windows` resolves it, so the two tasks agree on the path.
$cacheHome = if ($env:XDG_CACHE_HOME) { $env:XDG_CACHE_HOME } else { Join-Path $HOME '.cache' }
$caPath = Join-Path $cacheHome 'firezone\x509\ca.crt'

# A certificate can be issued on one machine and only its PKCS#12 carried to another, so a
# machine can hold one of ours without ever holding the CA. Then the person running this is the
# only one who can tell the certificates apart, and there has to be a terminal to ask them at.
if (-not (Test-Path -LiteralPath $caPath -PathType Leaf) -and [Console]::IsInputRedirected) {
    [Console]::Error.WriteLine("error: no test CA at $caPath, so nothing here can tell a test")
    [Console]::Error.WriteLine("certificate from any other under $commonName. Run 'mise run //:x509:create-ca',")
    [Console]::Error.WriteLine("or 'mise run //:x509:import-ca' if another machine has the CA, or run")
    [Console]::Error.WriteLine('this task from a terminal to choose by hand.')

    exit 1
}

# The install task writes into the machine store, so that is where the removal happens, and
# emptying it needs the same elevation filling it did.
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    [Console]::Error.WriteLine('error: removing from Cert:\LocalMachine\My needs an elevated shell.')
    [Console]::Error.WriteLine('Re-run this task from a PowerShell started as Administrator.')

    exit 1
}

# The file constructor reads PEM as well as DER, in Windows PowerShell and in PowerShell 7.
$ca = if (Test-Path -LiteralPath $caPath -PathType Leaf) {
    [Security.Cryptography.X509Certificates.X509Certificate2]::new($caPath)
}

# The CA is a trust anchor the portal knows and this machine does not, so the chain is built
# against it rather than the machine's own roots, and a certificate of ours that has expired is
# still ours to delete.
function Test-IssuedByTestCa {
    param($Certificate)

    $chain = [Security.Cryptography.X509Certificates.X509Chain]::new()
    $chain.ChainPolicy.RevocationMode = [Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
    $unknownRoot = [Security.Cryptography.X509Certificates.X509VerificationFlags]::AllowUnknownCertificateAuthority
    $expired = [Security.Cryptography.X509Certificates.X509VerificationFlags]::IgnoreNotTimeValid
    $chain.ChainPolicy.VerificationFlags = $unknownRoot -bor $expired
    $chain.ChainPolicy.ExtraStore.Add($ca) | Out-Null

    # `Build` reports every fault those two flags do not excuse, an issuer whose signature does
    # not verify included, so a certificate that merely names the CA does not pass here.
    $chain.Build($Certificate) -and
    $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate.Thumbprint -eq $ca.Thumbprint
}

# Enough of the certificate to recognise it by, since the answer is the only thing standing
# between it and deletion. `Write-Host` keeps it off the pipeline, which is the answer itself.
function Confirm-Delete {
    param($Certificate)

    Write-Host ''
    Write-Host ('    Subject    ' + $Certificate.Subject)
    Write-Host ('    Issuer     ' + $Certificate.Issuer)
    Write-Host ('    Thumbprint ' + $Certificate.Thumbprint)
    Write-Host ('    Expires    ' + $Certificate.NotAfter.ToString('u'))

    (Read-Host '    Delete it? [y/N]') -match '^y(es)?$'
}

Write-Output "==> Removing certificates for $commonName from Cert:\LocalMachine\My..."

if (-not $ca) {
    Write-Output "    No test CA at $caPath, so which of these are the test ones is yours to say."
}

# `GetNameInfo` reads the CN out of the subject, so a certificate whose subject merely contains
# that name somewhere is left alone: this task deletes private keys as an administrator.
$certificates = @(
    Get-ChildItem -Path 'Cert:\LocalMachine\My' | Where-Object {
        $_.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -eq $commonName
    }
)

if ($certificates.Count -eq 0) {
    Write-Output '    None were in the store.'
}

foreach ($certificate in $certificates) {
    $ours = if ($ca) { Test-IssuedByTestCa $certificate } else { Confirm-Delete $certificate }

    if (-not $ours) {
        Write-Output ('    Kept ' + $certificate.Thumbprint + ', issued by ' + $certificate.Issuer)

        continue
    }

    # `-DeleteKey` takes the private key with the certificate, whichever provider holds it,
    # so the key does not outlive the certificate it was imported with.
    Remove-Item -Path $certificate.PSPath -Force -DeleteKey
    Write-Output ('    Removed ' + $certificate.Thumbprint)
}

Write-Output ''
Write-Output 'A connected Tunnel service holds the certificate until it restarts, so restart it'
Write-Output 'to see the change.'
