<#
.SYNOPSIS
Prepares the desktop for screenshots and starts the GUI client against the in-process mock
Tunnel service.

.DESCRIPTION
Turns off the animations, fades and shadows that would make a capture timing-dependent, pins
the light theme and parks the cursor where a menu opened at it always fits, then starts the
client detached so a capture script can photograph it. The desktop has to be prepared before
the client starts: the theme registry keys are read at startup and writing them broadcasts no
settings change. Meant for the Windows CI runners; everything it finds goes to stdout because
the job log is all there is to debug with.
#>
param(
    [Parameter(Mandatory)] [string] $Exe
)

$ErrorActionPreference = 'Stop'
# .NET resolves relative paths against the process directory, not PowerShell's location.
$Exe = (Resolve-Path $Exe).Path
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class Win32 {
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool SystemParametersInfo(uint action, uint param, IntPtr pvParam, uint winIni);
}
'@

function Set-SystemParameter([string] $Name, [uint32] $Action, [bool] $Enabled) {
    $value = if ($Enabled) { [IntPtr] 1 } else { [IntPtr]::Zero }
    # SPIF_UPDATEINIFILE | SPIF_SENDCHANGE
    $ok = [Win32]::SystemParametersInfo($Action, 0, $value, 3)
    Write-Host "$Name = $Enabled (ok: $ok)"
}

Write-Host "Screen: $([Win32]::GetSystemMetrics(0))x$([Win32]::GetSystemMetrics(1))"

# Animations and shadows make the capture timing-dependent; the light theme keeps it deterministic.
Set-SystemParameter 'SPI_SETMENUANIMATION' 0x1003 $false
Set-SystemParameter 'SPI_SETMENUFADE' 0x1013 $false
Set-SystemParameter 'SPI_SETSELECTIONFADE' 0x1015 $false
Set-SystemParameter 'SPI_SETDROPSHADOW' 0x1025 $false
Set-SystemParameter 'SPI_SETUIEFFECTS' 0x103F $false
$personalize = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
New-Item -Path $personalize -Force | Out-Null
Set-ItemProperty -Path $personalize -Name AppsUseLightTheme -Value 1 -Type DWord
Set-ItemProperty -Path $personalize -Name SystemUsesLightTheme -Value 1 -Type DWord

# The menu opens at the cursor, so park it in a corner where it always fits.
[void][Win32]::SetCursorPos(40, 40)

# The GUI pipe that carries the capture's requests only admits processes carrying the installed
# package's identity, which a `cargo build` exe doesn't have; `--skip-peer-verification`
# relaxes that to the same test ACL the smoke test uses.
$arguments = @('--no-deep-links', '--no-elevation-check', '--no-error-dialog', '--skip-peer-verification', '--skip-portal-auth', '--mock-tunnel')
Write-Host "Launching $Exe $($arguments -join ' ')"
Start-Process -FilePath $Exe -ArgumentList $arguments
