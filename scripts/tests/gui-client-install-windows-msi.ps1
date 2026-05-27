# Install canary for the Windows MSI. Installs the package, launches
# the real GUI, and verifies two things:
#
#   1. The GUI connects to the tunnel service over the
#      package-SID-pinned pipe (it reaches its main loop and logs
#      "signed-out state"; a failed connect bails out instead, which
#      `--no-error-dialog` turns into a fast non-zero exit rather than
#      a modal-dialog hang).
#   2. An unprivileged (LUA-filtered) process is *denied* on both
#      pipes -- the actual point of the SID pinning.
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
$gui = "C:\Program Files\Firezone\Firezone.exe"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
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

Write-Output "==> Launching the GUI..."
$guiProc = Start-Process -FilePath $gui -ArgumentList `
    "--no-deep-links", "--no-elevation-check", "--no-error-dialog" -PassThru
try {
    # Wait for the GUI to connect to the tunnel pipe (it logs
    # "signed-out state" once the controller reaches its main loop) or
    # to bail out (a failed connect exits non-zero, dialog suppressed).
    $connected = $false
    for ($i = 1; $i -le 30; $i++) {
        $logs = Get-ChildItem $logDir -Filter *.log -ErrorAction SilentlyContinue
        if ($logs -and ($logs | Select-String -Pattern "signed-out state" -Quiet)) {
            $connected = $true
            Write-Output "==> GUI connected to the tunnel over the package-SID pipe"
            break
        }
        if ($guiProc.HasExited) { break }
        Start-Sleep -Seconds 1
    }
    if (-not $connected) {
        Write-Output "==> GUI still alive: $(-not $guiProc.HasExited) (exit code: $(if ($guiProc.HasExited) { $guiProc.ExitCode } else { 'n/a' }))"
        Write-Output "==> GUI log tail:"
        Get-ChildItem $logDir -Filter *.log -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime | Select-Object -Last 1 | Get-Content -Tail 40
        Write-Error "GUI did not connect to the tunnel over the package-SID pipe within 30s"
        exit 1
    }

    # The GUI is up and connected, so both pipes are bound (the tunnel
    # by the service, the GUI pipe by this process). Confirm an
    # unprivileged caller is denied on each -- the SID-pinning property.
    Write-Output "==> Verifying tunnel pipe denies unprivileged callers..."
    & "$scriptDir\expect-pipe-denied-lua-windows.ps1" -PipePath '\\.\pipe\dev.firezone.client_tunnel.ipc'
    Write-Output "==> Verifying GUI pipe denies unprivileged callers..."
    & "$scriptDir\expect-pipe-denied-lua-windows.ps1" -PipePath '\\.\pipe\dev.firezone.client_gui.ipc'
}
finally {
    Stop-Process -Id $guiProc.Id -Force -ErrorAction SilentlyContinue
}
