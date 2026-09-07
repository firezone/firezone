<#
.SYNOPSIS
Photographs the running GUI client's tray menu with one resource's submenu expanded.

.DESCRIPTION
Invokes the client as `open-tray-menu`, which asks the running instance over its GUI IPC pipe to
open its menu at the cursor, and keeps asking until the requested resource is listed. It then
clicks that item, captures the screen region covered by the menu windows, saves it as a PNG and
asks the instance to close the menu again. Meant for the Windows CI runners; everything it finds
goes to stdout because the job log is all there is to debug with.
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
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr hMenu);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetMenuString(IntPtr hMenu, uint item, StringBuilder text, int max, uint flags);
    [DllImport("user32.dll")] public static extern bool GetMenuItemRect(IntPtr hWnd, IntPtr hMenu, uint item, out RECT rect);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);

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

# Hidden so the console window of this short-lived process never covers the menu.
function Send-Command([string] $Command) {
    Write-Host "Asking the running instance to $Command"
    $request = Start-Process -FilePath $Exe -ArgumentList $Command -PassThru -WindowStyle Hidden
    if (-not $request.WaitForExit(30000)) {
        Stop-Process -Id $request.Id -Force -ErrorAction SilentlyContinue
        throw "'$Command' never exited"
    }
    Write-Host "'$Command' exited with code $($request.ExitCode)"

    return $request.ExitCode
}

# The menu lists resources only once the mock service has served them, so keep asking until
# the menu we want is on screen.
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$exitCode = 0
$menus = @()
$hmenu = [IntPtr]::Zero
$target = -1
while ($target -lt 0) {
    if ((Get-Date) -gt $deadline) {
        Write-Host "::error::Menu item '$Submenu' not found within $TimeoutSeconds seconds"
        $exitCode = 1
        $menus = @(Get-MenuRects)
        break
    }

    if ((Send-Command 'open-tray-menu') -ne 0) {
        Write-Host 'The running instance did not take the request; asking again'
        Start-Sleep -Milliseconds 500
        continue
    }

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

    # MN_GETHMENU hands out the HMENU behind the popup window, which is how the item rows are found.
    $hmenu = [Win32]::SendMessage($menus[0].Handle, 0x01E1, [IntPtr]::Zero, [IntPtr]::Zero)
    $found = @(Get-MenuItems $hmenu | Where-Object { $_.Text -eq $Submenu })
    if ($found.Count -gt 0) {
        $target = $found[0].Index
        break
    }

    Write-Host "'$Submenu' is not in the menu yet; closing it and asking again"
    [void] (Send-Command 'close-tray-menu')
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

[void] (Send-Command 'close-tray-menu')

exit $exitCode
