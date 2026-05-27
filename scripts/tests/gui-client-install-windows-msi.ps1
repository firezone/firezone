# Install canary for the Windows MSI. Installs the package, then
# launches the real GUI and checks it exits cleanly. The GUI connects
# to the tunnel service over the package-SID-pinned pipe at startup;
# if it can't (no package identity, or the DACL denies it) it bails
# out non-zero. `--quit-after` makes a successful run exit 0 on its
# own, and `--no-error-dialog` keeps a failure from blocking on a
# modal dialog with no one to dismiss it. So: exit 0 == the GUI
# connected; non-zero == it didn't.
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

Write-Output "==> Launching the GUI to exercise the tunnel-pipe connect..."
$guiProc = Start-Process -FilePath $gui -ArgumentList `
    "--no-deep-links", "--no-elevation-check", "--no-error-dialog", "--quit-after", "20" `
    -PassThru
# Bounded wait so a hang can't stall the job; a clean run exits well
# inside this (connect failure bails in seconds, success after ~20s).
if (-not $guiProc.WaitForExit(90000)) {
    Stop-Process -Id $guiProc.Id -Force -ErrorAction SilentlyContinue
    Write-Error "GUI did not exit within 90s"
    exit 1
}
if ($guiProc.ExitCode -ne 0) {
    Write-Output "==> GUI log tail:"
    Get-ChildItem "$env:LOCALAPPDATA\dev.firezone.client\data\logs" -Filter *.log -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime | Select-Object -Last 1 | Get-Content -Tail 40
    Write-Error "GUI exited $($guiProc.ExitCode): it could not connect to the tunnel over the package-SID pipe"
    exit 1
}
Write-Output "==> GUI connected to the tunnel and exited cleanly"
