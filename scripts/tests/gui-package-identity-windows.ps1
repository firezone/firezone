# Verify a running Firezone process has the MSIX package identity
# attached. The kernel reads the embedded SXS / fusion manifest in
# `Firezone.exe` at `CreateProcess` time and matches its `<msix>`
# element against the registered package; if either piece is
# missing, `GetPackageFullName` returns
# `APPMODEL_ERROR_NO_PACKAGE` (15700).
#
# Takes a PID rather than launching its own process so the caller
# can reuse a long-running Firezone instance (e.g. one bound to a
# pipe for the DACL probes), avoiding the double-launch race.

param(
    [Parameter(Mandatory)]
    [int]$ProcessId
)

$ErrorActionPreference = "Stop"

Add-Type -MemberDefinition @"
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern int GetPackageFullName(IntPtr hProcess, ref int len, System.Text.StringBuilder buf);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern IntPtr OpenProcess(int desiredAccess, bool inheritHandle, int processId);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool CloseHandle(IntPtr hObject);
"@ -Name PInvoke -Namespace W32

$PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
$h = [W32.PInvoke]::OpenProcess($PROCESS_QUERY_LIMITED_INFORMATION, $false, $ProcessId)
if ($h -eq [IntPtr]::Zero) {
    $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    Write-Error "OpenProcess($ProcessId) failed (lastError=$err)"
    exit 1
}

$len = 256
$sb = New-Object System.Text.StringBuilder $len
$rc = [W32.PInvoke]::GetPackageFullName($h, [ref]$len, $sb)
[W32.PInvoke]::CloseHandle($h) | Out-Null

if ($rc -ne 0) {
    # 15700 == 0x3D54 == APPMODEL_ERROR_NO_PACKAGE
    Write-Error "PID $ProcessId has no package identity (GetPackageFullName rc=$rc, len=$len)"
    exit 1
}

$pfn = $sb.ToString()
Write-Output "PID ${ProcessId} package: $pfn"
if ($pfn -notlike "Firezone.Client.GUI_*") {
    Write-Error "PID $ProcessId has unexpected package family `"$pfn`""
    exit 1
}
