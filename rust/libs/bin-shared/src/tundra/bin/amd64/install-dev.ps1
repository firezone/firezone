<#
.SYNOPSIS
    Prepares a developer machine for the test-signed Tundra driver and installs it.

.DESCRIPTION
    Run from an elevated PowerShell in the directory containing tundra.inf,
    tundra.sys, tundra.cat and tundra-test.cer (e.g. an extracted CI artifact).

    1. Checks that test signing is enabled (and offers to enable it; needs a reboot
       and Secure Boot must be off).
    2. Trusts tundra-test.cer (LocalMachine Root + TrustedPublisher) so the package
       installs without prompts.
    3. Adds the driver package to the driver store.

    Use -Uninstall to remove the package from the driver store again.
#>
param(
    [string]$Path = $PSScriptRoot,
    [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated PowerShell.'
}

if ($Uninstall) {
    $drivers = pnputil /enum-drivers | Out-String
    $found = [regex]::Matches($drivers, '(?ms)Published Name:\s+(oem\d+\.inf)\s+Original Name:\s+tundra\.inf')
    foreach ($m in $found) {
        pnputil /delete-driver $m.Groups[1].Value /uninstall /force
    }
    return
}

$testSigning = (bcdedit /enum '{current}' | Select-String -Pattern '^testsigning\s+Yes') -ne $null
if (-not $testSigning) {
    Write-Warning 'Test signing is disabled. Test-signed drivers will not load.'
    $answer = Read-Host 'Enable test signing now? Requires Secure Boot to be disabled and a reboot. [y/N]'
    if ($answer -eq 'y') {
        bcdedit /set testsigning on
        if ($LASTEXITCODE -ne 0) { throw 'bcdedit failed; is Secure Boot disabled?' }
        Write-Host 'Test signing enabled. Reboot, then run this script again.'
        return
    }
}

$cer = Join-Path $Path 'tundra-test.cer'
foreach ($store in 'Root', 'TrustedPublisher') {
    Import-Certificate -FilePath $cer -CertStoreLocation "Cert:\LocalMachine\$store" | Out-Null
}

pnputil /add-driver (Join-Path $Path 'tundra.inf')
if ($LASTEXITCODE -ne 0) { throw 'pnputil failed' }
Write-Host 'Tundra driver package installed. Adapters are created on demand by the application.'
