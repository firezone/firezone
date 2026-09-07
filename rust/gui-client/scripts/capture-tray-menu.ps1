<#
.SYNOPSIS
Photographs the tray menu of a debug GUI client with one resource's submenu expanded.

.DESCRIPTION
Launches the client against the in-process mock Tunnel service with `--popup-tray-menu`,
which pops the connected-state menu up at the cursor. The script then clicks the requested
submenu item, captures the screen region covered by the menu windows and saves it as a PNG.
Meant for the Windows CI runners; everything it finds goes to stdout because the job log is
all there is to debug with.
#>
param(
    [Parameter(Mandatory)] [string] $Exe,
    [Parameter(Mandatory)] [string] $Output,
    [string] $Submenu = 'Engineering wiki',
    [int] $TimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public struct RECT { public int Left, Top, Right, Bottom; }

public static class Win32 {
    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll")] static extern int GetClassName(IntPtr hWnd, StringBuilder name, int max);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr hMenu);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetMenuString(IntPtr hMenu, uint item, StringBuilder text, int max, uint flags);
    [DllImport("user32.dll")] public static extern bool GetMenuItemRect(IntPtr hWnd, IntPtr hMenu, uint item, out RECT rect);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool SystemParametersInfo(uint action, uint param, IntPtr pvParam, uint winIni);

    // Popup menus are windows of the system class "#32768", one per open level.
    public static IntPtr[] MenuWindows() {
        var found = new List<IntPtr>();
        EnumWindows((hWnd, _) => {
            var name = new StringBuilder(64);
            GetClassName(hWnd, name, name.Capacity);
            if (name.ToString() == "#32768" && IsWindowVisible(hWnd)) found.Add(hWnd);
            return true;
        }, IntPtr.Zero);
        return found.ToArray();
    }

    public static string MenuItemText(IntPtr hMenu, uint index) {
        var text = new StringBuilder(256);
        GetMenuString(hMenu, index, text, text.Capacity, 0x400 /* MF_BYPOSITION */);
        return text.ToString();
    }
}
'@

function Set-SystemParameter([string] $Name, [uint32] $Action, [bool] $Enabled) {
    $value = if ($Enabled) { [IntPtr] 1 } else { [IntPtr]::Zero }
    # SPIF_UPDATEINIFILE | SPIF_SENDCHANGE
    $ok = [Win32]::SystemParametersInfo($Action, 0, $value, 3)
    Write-Host "$Name = $Enabled (ok: $ok)"
}

function Get-MenuRects {
    foreach ($hwnd in [Win32]::MenuWindows()) {
        $rect = New-Object RECT
        [void][Win32]::GetWindowRect($hwnd, [ref] $rect)
        [pscustomobject] @{ Handle = $hwnd; Rect = $rect }
    }
}

function Show-MenuRects([string] $Label, $Windows) {
    Write-Host "${Label}: $(@($Windows).Count) menu window(s)"
    foreach ($w in $Windows) {
        $r = $w.Rect
        Write-Host "  hwnd=$($w.Handle) left=$($r.Left) top=$($r.Top) right=$($r.Right) bottom=$($r.Bottom)"
    }
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

# The client pops the menu up at the cursor.
[void][Win32]::SetCursorPos(40, 40)

$arguments = @('--no-deep-links', '--no-elevation-check', '--no-error-dialog', '--skip-portal-auth', '--mock-tunnel', '--popup-tray-menu')
Write-Host "Launching $Exe $($arguments -join ' ')"
$process = Start-Process -FilePath $Exe -ArgumentList $arguments -PassThru

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$menus = @()
while (@($menus).Count -eq 0) {
    if ($process.HasExited) {
        throw "The client exited with code $($process.ExitCode) before showing a menu"
    }
    if ((Get-Date) -gt $deadline) {
        throw "No popup menu appeared within $TimeoutSeconds seconds"
    }
    Start-Sleep -Milliseconds 250
    $menus = @(Get-MenuRects)
}
Start-Sleep -Milliseconds 500
$menus = @(Get-MenuRects)
Show-MenuRects 'Menu open' $menus
Write-Host "Foreground window: $([Win32]::GetForegroundWindow())"

# MN_GETHMENU hands out the HMENU behind the popup window, which is how the item rows are found.
$root = $menus[0].Handle
$hmenu = [Win32]::SendMessage($root, 0x01E1, [IntPtr]::Zero, [IntPtr]::Zero)
$count = [Win32]::GetMenuItemCount($hmenu)
Write-Host "Root menu $hmenu has $count items:"
$target = -1
for ($i = 0; $i -lt $count; $i++) {
    $text = [Win32]::MenuItemText($hmenu, $i)
    Write-Host "  [$i] '$text'"
    if ($text.Replace('&', '') -eq $Submenu) { $target = $i }
}

$exitCode = 0
if ($target -lt 0) {
    Write-Host "::error::Menu item '$Submenu' not found"
    $exitCode = 1
} else {
    $rect = New-Object RECT
    [void][Win32]::GetMenuItemRect([IntPtr]::Zero, $hmenu, $target, [ref] $rect)
    $x = [int] (($rect.Left + $rect.Right) / 2)
    $y = [int] (($rect.Top + $rect.Bottom) / 2)
    Write-Host "Clicking '$Submenu' (item $target) at $x,$y"
    [void][Win32]::SetCursorPos($x, $y)
    Start-Sleep -Milliseconds 100
    [Win32]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero) # MOUSEEVENTF_LEFTDOWN
    [Win32]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero) # MOUSEEVENTF_LEFTUP
    Start-Sleep -Milliseconds 500

    $menus = @(Get-MenuRects)
    Show-MenuRects 'Submenu expanded' $menus
    if (@($menus).Count -lt 2) {
        Write-Host "::error::The submenu did not open"
        $exitCode = 1
    }
}

$left = ($menus | ForEach-Object { $_.Rect.Left } | Measure-Object -Minimum).Minimum
$top = ($menus | ForEach-Object { $_.Rect.Top } | Measure-Object -Minimum).Minimum
$right = ($menus | ForEach-Object { $_.Rect.Right } | Measure-Object -Maximum).Maximum
$bottom = ($menus | ForEach-Object { $_.Rect.Bottom } | Measure-Object -Maximum).Maximum
$width = $right - $left
$height = $bottom - $top
Write-Host "Capturing $left,$top ${width}x${height}"

$bitmap = New-Object System.Drawing.Bitmap $width, $height
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.CopyFromScreen($left, $top, 0, 0, $bitmap.Size)
New-Item -ItemType Directory -Path (Split-Path -Parent $Output) -Force | Out-Null
$bitmap.Save($Output, [System.Drawing.Imaging.ImageFormat]::Png)
$graphics.Dispose()
$bitmap.Dispose()
Write-Host "Saved $Output ($((Get-Item $Output).Length) bytes)"

# One Escape per open level, then stop the client.
foreach ($level in 1..2) {
    [Win32]::keybd_event(0x1B, 0, 0, [UIntPtr]::Zero)
    [Win32]::keybd_event(0x1B, 0, 2, [UIntPtr]::Zero) # KEYEVENTF_KEYUP
    Start-Sleep -Milliseconds 100
}
Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue

exit $exitCode
