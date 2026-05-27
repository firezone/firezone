# Install canary for the Windows MSI. Verifies that the sparse
# MSIX registers, the package is queryable by the runner's user,
# and a freshly-launched `Firezone.exe` carries the package
# identity that the tunnel-pipe DACL pins access to.
#
# PowerShell rather than bash because MSYS2's process spawn drops
# the kernel's SXS-manifest -> registered-package identity
# binding: `Firezone.exe` launched via bash backgrounding has no
# package identity, while the same binary launched via
# `Start-Process` does.

$ErrorActionPreference = "Stop"

if (-not $env:BINARY_DEST_PATH) {
    Write-Error "BINARY_DEST_PATH not set"
    exit 1
}

$msi = "$($env:BINARY_DEST_PATH).msi"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Output "==> Installing $msi..."
$msiproc = Start-Process -FilePath "msiexec.exe" `
    -ArgumentList "/i", $msi, "/l*v!", "install.log", "/qn" `
    -Wait -PassThru -NoNewWindow
if ($msiproc.ExitCode -ne 0) {
    Write-Error "msiexec exited with $($msiproc.ExitCode)"
    exit 1
}

Write-Output "==> Checking the tunnel service is running..."
$null = sc.exe query FirezoneClientTunnelService | Select-String "RUNNING"
if ($LASTEXITCODE -ne 0) {
    Write-Error "FirezoneClientTunnelService is not running"
    exit 1
}

# `register-sparse.exe` (MSI deferred CA, runs as LocalSystem)
# calls `ProvisionPackageForAllUsersAsync`, which returns success
# before the AppX deployment service has finished syncing the
# per-user registration. Poll `Get-AppxPackage` until the runner's
# session sees the package before launching the GUI.
Write-Output "==> Waiting for AppX deployment service to register the package..."
$pfn = $null
for ($i = 1; $i -le 15; $i++) {
    $pfn = (Get-AppxPackage Firezone.Client.GUI | Select-Object -First 1).PackageFullName
    if ($pfn) {
        Write-Output "==> Get-AppxPackage settled after $i probe(s) (~$($i * 2)s): $pfn"
        break
    }
    Start-Sleep -Seconds 2
}
if (-not $pfn) {
    Write-Error "Get-AppxPackage Firezone.Client.GUI returned nothing after 30s"
    exit 1
}

$gui = "C:\Program Files\Firezone\Firezone.exe"

Write-Output "==> Launching Firezone.exe..."
$proc = Start-Process -FilePath $gui `
    -ArgumentList "--no-deep-links", "--no-elevation-check", "--no-error-dialog" -PassThru
try {
    Write-Output "==> Verifying Firezone.exe has package identity attached..."
    & "$scriptDir\gui-package-identity-windows.ps1" -ProcessId $proc.Id
    Write-Output "==> Package identity attached to Firezone.exe"

    Write-Output "==> Verifying tunnel pipe denies non-Firezone-signed callers..."
    & "$scriptDir\expect-pipe-denied-lua-windows.ps1" -PipePath '\\.\pipe\dev.firezone.client_tunnel.ipc'
    Write-Output "==> Tunnel pipe DACL pinned to package SID"

    Write-Output "==> Verifying GUI pipe denies non-Firezone-signed callers..."
    & "$scriptDir\expect-pipe-denied-lua-windows.ps1" -PipePath '\\.\pipe\dev.firezone.client_gui.ipc'
    Write-Output "==> GUI pipe DACL pinned to package SID"

    # The GUI must still be running. If it had failed to connect to the
    # tunnel it would have bailed out (non-zero, dialog suppressed)
    # before now.
    if ($proc.HasExited) {
        Write-Error "Firezone.exe exited prematurely with code $($proc.ExitCode)"
        exit 1
    }
    Write-Output "==> Firezone.exe still running after all checks"
}
finally {
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
}
