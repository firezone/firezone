#!/usr/bin/env bash
#MISE description="Import the test X.509 client certificate into the Windows certificate store"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./lib.sh
source "${SCRIPT_DIR}/lib.sh"

require_os 'MINGW* | MSYS* | CYGWIN*' 'a Windows certificate store'
require_p12

# Windows PowerShell rather than pwsh: the PKI module that provides Import-PfxCertificate
# ships with it.
command -v powershell.exe >/dev/null || {
    echo "error: powershell.exe is not on PATH" >&2
    exit 1
}

command -v cygpath >/dev/null || {
    echo "error: cygpath is required to translate paths; run this from Git Bash" >&2
    exit 1
}

p12_windows="$(cygpath -w "$P12_PATH")"

work="$(mktemp -d)"
# shellcheck disable=SC2064 # `work` is expanded now on purpose; the trap outlives the variable.
trap "rm -rf '${work}'" EXIT

script="${work}/import.ps1"
cat >"$script" <<'POWERSHELL'
$ErrorActionPreference = 'Stop'

$password = ConvertTo-SecureString -String $env:P12_PASSWORD -AsPlainText -Force
$imported = @(Import-PfxCertificate -FilePath $env:P12_WINDOWS_PATH -CertStoreLocation 'Cert:\CurrentUser\My' -Password $password)

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
Write-Warning ('  certutil -f -user -p ' + $env:P12_PASSWORD + ' -csp "Microsoft Software Key Storage Provider" -importpfx My ' + $env:P12_WINDOWS_PATH)
}
POWERSHELL

echo "==> Importing ${P12_PATH} into Cert:\\CurrentUser\\My..."

# MSYS rewrites arguments that look like paths, which would mangle the script path.
MSYS2_ARG_CONV_EXCL='*' \
    P12_WINDOWS_PATH="$p12_windows" \
    P12_PASSWORD="$P12_PASSWORD" \
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
    -File "$(cygpath -w "$script")"

echo
echo "'firezone-client-tunnel.exe x509' prints what the Client makes of the store."
echo
echo "That store belongs to your account. The installed Tunnel service runs as LocalSystem and"
echo "will not see it; give the service its own copy from an elevated PowerShell:"
echo
echo "    Import-PfxCertificate -FilePath '${p12_windows}' -CertStoreLocation Cert:\\LocalMachine\\My -Password (ConvertTo-SecureString -String '${P12_PASSWORD}' -AsPlainText -Force)"
