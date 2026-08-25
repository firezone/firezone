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
# Client finds it and how this task knows which certificates it put there.
#
# The CA the certificate was issued from has its own tasks and its own lifetime, so it stays
# where it is even though `//:x509:install-windows` carries it into the store alongside this
# certificate.
$commonName = 'dev.firezone.device-trust'

# The install task writes into the machine store, so that is where the removal happens, and
# emptying it needs the same elevation filling it did.
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    [Console]::Error.WriteLine('error: removing from Cert:\LocalMachine\My needs an elevated shell.')
    [Console]::Error.WriteLine('Re-run this task from a PowerShell started as Administrator.')

    exit 1
}

Write-Output "==> Removing certificates for $commonName from Cert:\LocalMachine\My..."

# Matched on the common name rather than a thumbprint, because a machine that ran the install
# task more than once holds one certificate per run and all of them are throwaway test material.
# `GetNameInfo` reads the CN out of the subject, so a certificate whose subject merely contains
# that name somewhere is left alone: this task deletes private keys as an administrator.
$certificates = @(
    Get-ChildItem -Path 'Cert:\LocalMachine\My' | Where-Object {
        $_.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) -eq $commonName
    }
)

if ($certificates.Count -eq 0) {
    Write-Output '    None were in the store.'
} else {
    foreach ($certificate in $certificates) {
        # `-DeleteKey` takes the private key with the certificate, whichever provider holds it,
        # so the key does not outlive the certificate it was imported with.
        Remove-Item -Path $certificate.PSPath -Force -DeleteKey
        Write-Output ('    Removed ' + $certificate.Thumbprint)
    }
}

Write-Output ''
Write-Output 'The Client has no identity to find now. A connected Tunnel service holds the'
Write-Output 'certificate until it restarts, so restart it to see the change.'
Write-Output ''
Write-Output "'firezone-client-tunnel.exe x509' prints what the Client makes of the store."
