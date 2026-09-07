<#
.SYNOPSIS
Photographs the tray menu of a debug GUI client with one resource's submenu expanded.

.DESCRIPTION
Launches the client against the in-process mock Tunnel service, then invokes the same binary
again with `--popup-tray-menu`, which asks the running instance over its GUI IPC pipe to pop
the connected-state menu up at the cursor. The script then clicks the requested submenu item,
captures the screen region covered by the menu windows and saves it as a PNG. Meant for the
Windows CI runners; everything it finds goes to stdout because the job log is all there is to
debug with.
#>
param(
    [Parameter(Mandatory)] [string] $Exe,
    [Parameter(Mandatory)] [string] $Output,
    [string] $Submenu = 'Engineering wiki',
    [int] $TimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
# .NET resolves relative paths against the process directory, not PowerShell's location.
$Exe = (Resolve-Path $Exe).Path
if (-not [System.IO.Path]::IsPathRooted($Output)) {
    $Output = Join-Path (Get-Location).Path $Output
}
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

function Get-MenuItems([IntPtr] $Menu) {
    $count = [Win32]::GetMenuItemCount($Menu)
    Write-Host "Menu $Menu has $count items:"
    for ($i = 0; $i -lt $count; $i++) {
        $text = [Win32]::MenuItemText($Menu, $i).Replace('&', '')
        Write-Host "  [$i] '$text'"
        [pscustomobject] @{ Index = $i; Text = $text }
    }
}

function Send-Escape([int] $Levels) {
    foreach ($level in 1..$Levels) {
        [Win32]::keybd_event(0x1B, 0, 0, [UIntPtr]::Zero)
        [Win32]::keybd_event(0x1B, 0, 2, [UIntPtr]::Zero) # KEYEVENTF_KEYUP
        Start-Sleep -Milliseconds 100
    }
}

# A request sent before the client holds the launch lock would take the lock itself and turn
# into the app, so wait for the pipe the running instance answers on. Enumerating the pipe
# filesystem is the only way to see a named pipe; `Test-Path` cannot.
function Wait-ForGuiPipe {
    $pipe = 'dev.firezone.client_gui.ipc'
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        try {
            if ([System.IO.Directory]::GetFiles('\\.\pipe\') -match [regex]::Escape($pipe)) {
                Write-Host "The running instance is listening on $pipe"
                return
            }
        } catch {
            Write-Host "Cannot list named pipes ($_); falling back to a fixed head start"
            Start-Sleep -Seconds 5
            return
        }
        Start-Sleep -Milliseconds 250
    }
    Write-Host "::warning::$pipe never showed up; requesting the menu anyway"
}

# Hidden so the console window of this short-lived process never covers the menu.
function Request-Popup {
    Write-Host "Requesting the menu: $Exe $($popupArguments -join ' ')"
    $popup = Start-Process -FilePath $Exe -ArgumentList $popupArguments -PassThru -WindowStyle Hidden
    if (-not $popup.WaitForExit(30000)) {
        Stop-Process -Id $popup.Id -Force -ErrorAction SilentlyContinue
        throw "The popup request never exited; it may have taken the launch lock itself"
    }
    # `--no-error-dialog` makes the client report the hand-off to the running instance as a
    # failure, so the code is only worth logging: whether the menu opens is the real signal.
    Write-Host "Popup request exited with code $($popup.ExitCode)"
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

# The menu pops up at the cursor, so park it in a corner where it always fits.
[void][Win32]::SetCursorPos(40, 40)

# The GUI pipe that carries the popup request only admits processes carrying the installed
# package's identity, which a `cargo build` exe doesn't have; `--skip-peer-verification`
# relaxes that to the same test ACL the smoke test uses.
$sharedArguments = @('--no-deep-links', '--no-elevation-check', '--no-error-dialog', '--skip-peer-verification')
$arguments = $sharedArguments + @('--skip-portal-auth', '--mock-tunnel')
$popupArguments = $sharedArguments + @('--popup-tray-menu')
Write-Host "Launching $Exe $($arguments -join ' ')"
$process = Start-Process -FilePath $Exe -ArgumentList $arguments -PassThru

Wait-ForGuiPipe

# The menu lists resources only once the mock service has served them, so keep asking until
# the menu we want is on screen.
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$exitCode = 0
$menus = @()
$hmenu = [IntPtr]::Zero
$target = -1
while ($target -lt 0) {
    if ($process.HasExited) {
        throw "The client exited with code $($process.ExitCode) before showing a menu"
    }
    if ((Get-Date) -gt $deadline) {
        Write-Host "::error::Menu item '$Submenu' not found within $TimeoutSeconds seconds"
        $exitCode = 1
        $menus = @(Get-MenuRects)
        break
    }

    Request-Popup

    $appeared = (Get-Date).AddSeconds(5)
    $menus = @(Get-MenuRects)
    while ($menus.Count -eq 0 -and (Get-Date) -lt $appeared) {
        Start-Sleep -Milliseconds 250
        $menus = @(Get-MenuRects)
    }
    if ($menus.Count -eq 0) {
        Write-Host 'No menu appeared; asking again'
        continue
    }

    Start-Sleep -Milliseconds 500
    $menus = @(Get-MenuRects)
    Show-MenuRects 'Menu open' $menus
    if ($menus.Count -eq 0) {
        Write-Host 'The menu closed again within 500 ms; asking again'
        continue
    }
    Write-Host "Foreground window: $([Win32]::GetForegroundWindow())"

    # MN_GETHMENU hands out the HMENU behind the popup window, which is how the item rows are found.
    $hmenu = [Win32]::SendMessage($menus[0].Handle, 0x01E1, [IntPtr]::Zero, [IntPtr]::Zero)
    $found = @(Get-MenuItems $hmenu | Where-Object { $_.Text -eq $Submenu })
    if ($found.Count -gt 0) {
        $target = $found[0].Index
        break
    }

    Write-Host "'$Submenu' is not in the menu yet; dismissing it and asking again"
    Send-Escape 1
    Start-Sleep -Milliseconds 500
}

if ($target -ge 0) {
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

if ($menus.Count -eq 0) {
    Write-Host '::error::No menu is on screen, nothing to capture'
    exit 1
}

$left = [int] ($menus | ForEach-Object { $_.Rect.Left } | Measure-Object -Minimum).Minimum
$top = [int] ($menus | ForEach-Object { $_.Rect.Top } | Measure-Object -Minimum).Minimum
$right = [int] ($menus | ForEach-Object { $_.Rect.Right } | Measure-Object -Maximum).Maximum
$bottom = [int] ($menus | ForEach-Object { $_.Rect.Bottom } | Measure-Object -Maximum).Maximum
$width = $right - $left
$height = $bottom - $top
Write-Host "Capturing $left,$top ${width}x${height}"

# Only the menus themselves; the corners of their bounding box stay transparent.
$bitmap = New-Object System.Drawing.Bitmap $width, $height, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.Clear([System.Drawing.Color]::Transparent)
foreach ($w in $menus) {
    $r = $w.Rect
    $part = New-Object System.Drawing.Bitmap ($r.Right - $r.Left), ($r.Bottom - $r.Top), ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $partGraphics = [System.Drawing.Graphics]::FromImage($part)
    $partGraphics.CopyFromScreen($r.Left, $r.Top, 0, 0, $part.Size)
    $partGraphics.Dispose()
    $graphics.DrawImage($part, $r.Left - $left, $r.Top - $top)
    $part.Dispose()
}
New-Item -ItemType Directory -Path (Split-Path -Parent $Output) -Force | Out-Null
$bitmap.Save($Output, [System.Drawing.Imaging.ImageFormat]::Png)
$graphics.Dispose()
$bitmap.Dispose()
Write-Host "Saved $Output ($((Get-Item $Output).Length) bytes)"

# One Escape per open level, then stop the client.
Send-Escape 2
Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue

exit $exitCode
