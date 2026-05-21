# Verify the running tunnel service's process token has the
# Firezone MSIX package identity attached. `GetPackageFullName`
# returns `APPMODEL_ERROR_NO_PACKAGE` (15700) on processes without
# identity, even when `Get-AppxPackage` shows the package is
# registered — the most common cause is `Executable=` paths in
# `AppxManifest.xml` that don't resolve to the actual EXEs at the
# external location.

$ErrorActionPreference = "Stop"

$svcPid = (Get-Process -Name firezone-client-tunnel -ErrorAction SilentlyContinue |
    Select-Object -First 1).Id
if (-not $svcPid) {
    Write-Error "firezone-client-tunnel.exe not running"
    exit 1
}

Add-Type -MemberDefinition @"
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern int GetPackageFullName(IntPtr hProcess, ref int len, System.Text.StringBuilder buf);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern IntPtr OpenProcess(int desiredAccess, bool inheritHandle, int processId);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool CloseHandle(IntPtr hObject);
"@ -Name PInvoke -Namespace W32

# PROCESS_QUERY_LIMITED_INFORMATION.
$h = [W32.PInvoke]::OpenProcess(0x1000, $false, $svcPid)
if ($h -eq [IntPtr]::Zero) {
    Write-Error "OpenProcess($svcPid) failed (lastError=$([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
    exit 1
}

$len = 256
$sb = New-Object System.Text.StringBuilder $len
$rc = [W32.PInvoke]::GetPackageFullName($h, [ref]$len, $sb)
[W32.PInvoke]::CloseHandle($h) | Out-Null

if ($rc -ne 0) {
    # 15700 == 0x3D54 == APPMODEL_ERROR_NO_PACKAGE
    Write-Error "Tunnel service has no package identity (GetPackageFullName rc=$rc, len=$len)"
    exit 1
}

$pfn = $sb.ToString()
Write-Output "Tunnel service package: $pfn"
if ($pfn -notlike "Firezone.Client.GUI_*") {
    Write-Error "Tunnel service has unexpected package family `"$pfn`""
    exit 1
}
