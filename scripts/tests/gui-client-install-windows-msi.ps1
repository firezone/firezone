# Install canary for the Windows MSI. Installs the package, then
# launches the real GUI and verifies it connects to the tunnel
# service over the package-SID-pinned pipe -- which only works if the
# MSI registered the package for the user and the kernel attached the
# package identity. A denied connect means the GUI never reaches its
# main loop, so the connect check is the gating signal.
#
# PowerShell rather than bash because MSYS2's process spawn drops the
# kernel's SXS-manifest -> registered-package identity binding:
# `Firezone.exe` launched via bash backgrounding has no package
# identity, while the same binary launched via `Start-Process` does.

$ErrorActionPreference = "Stop"

if (-not $env:BINARY_DEST_PATH) {
    Write-Error "BINARY_DEST_PATH not set"
    exit 1
}

$msi = "$($env:BINARY_DEST_PATH).msi"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$gui = "C:\Program Files\Firezone\Firezone.exe"
# Filesystem write virtualization is disabled in the manifest, so the
# identity-carrying GUI logs to the real path, not a package container.
$logDir = "$env:LOCALAPPDATA\dev.firezone.client\data\logs"

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

# Launch the real GUI and confirm it connects to the tunnel service
# over the package-SID-pinned pipe. The GUI opens the tunnel pipe at
# controller startup (before sign-in); only after a successful
# connect + Hello does the controller reach its main loop and log
# "signed-out state" at INFO. Poll the log for that marker rather
# than waiting for a graceful exit (the full Tauri GUI doesn't
# cleanly quit in headless CI), and kill it afterwards. A denied
# connect never logs the marker, so the poll times out and fails.
Write-Output "==> Launching the GUI to exercise the tunnel-pipe connect..."
$guiProc = Start-Process -FilePath $gui `
    -ArgumentList "--no-deep-links", "--no-elevation-check" -PassThru
try {
    $connected = $false
    for ($i = 1; $i -le 30; $i++) {
        $logs = Get-ChildItem $logDir -Filter *.log -ErrorAction SilentlyContinue
        if ($logs -and ($logs | Select-String -Pattern "signed-out state" -Quiet)) {
            $connected = $true
            Write-Output "==> GUI reached its main loop after ~${i}s (tunnel pipe connect succeeded)"
            break
        }
        if ($guiProc.HasExited) {
            Write-Output "GUI exited early with code $($guiProc.ExitCode)"
            break
        }
        Start-Sleep -Seconds 1
    }
    if (-not $connected) {
        Write-Output "==> GUI still alive: $(-not $guiProc.HasExited)"
        Get-AppxPackage -AllUsers Firezone.Client.GUI |
            Format-List PackageFullName, Status, PackageUserInformation
        Write-Output "==> Log tail:"
        Get-ChildItem $logDir -Filter *.log -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime | Select-Object -Last 1 | Get-Content -Tail 40
        Write-Error "GUI did not connect to the tunnel over the package-SID pipe within 30s"
        exit 1
    }
    Write-Output "==> GUI connected to the tunnel over the package-SID pipe"

    # The connect proves the DACL grants the package SID; these prove
    # it still denies everyone else (the actual hardening). Both pipes
    # are bound now -- the tunnel by the service, the GUI by this
    # process -- so probe them with a LUA-filtered (non-admin,
    # no-package-SID) token and expect ACCESS_DENIED.
    Write-Output "==> Verifying tunnel pipe denies non-Firezone callers..."
    & "$scriptDir\expect-pipe-denied-lua-windows.ps1" -PipePath '\\.\pipe\dev.firezone.client_tunnel.ipc'
    Write-Output "==> Verifying GUI pipe denies non-Firezone callers..."
    & "$scriptDir\expect-pipe-denied-lua-windows.ps1" -PipePath '\\.\pipe\dev.firezone.client_gui.ipc'
}
finally {
    Stop-Process -Id $guiProc.Id -Force -ErrorAction SilentlyContinue
}
