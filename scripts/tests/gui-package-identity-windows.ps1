# Verify the GUI binary has the Firezone MSIX package identity
# attached when launched. The kernel reads the embedded SXS / fusion
# manifest in `Firezone.exe` at `CreateProcess` time and matches its
# `<msix>` element against the registered package; if either piece
# is missing, `GetPackageFullName` on the launched process returns
# `APPMODEL_ERROR_NO_PACKAGE` (15700).
#
# `Firezone.exe --help` triggers clap's early-exit path so the
# process lifetime is bounded to a few hundred ms — long enough for
# `OpenProcess` to race in and read the token.

$ErrorActionPreference = "Stop"

$exe = "C:\Program Files\Firezone\Firezone.exe"
if (-not (Test-Path $exe)) {
    Write-Error "Firezone.exe not found at $exe"
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

$proc = Start-Process -FilePath $exe -ArgumentList "--help" -PassThru -WindowStyle Hidden

# Race against the process's exit: `--help` returns in ~100ms, but
# the kernel object stays alive as long as we hold a process handle.
# Open as soon as we can; bail after a generous retry budget.
$PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
$h = [IntPtr]::Zero
for ($i = 0; $i -lt 100; $i++) {
    $h = [W32.PInvoke]::OpenProcess($PROCESS_QUERY_LIMITED_INFORMATION, $false, $proc.Id)
    if ($h -ne [IntPtr]::Zero) { break }
    Start-Sleep -Milliseconds 20
}
if ($h -eq [IntPtr]::Zero) {
    Write-Error "OpenProcess($($proc.Id)) failed after retries (lastError=$([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
    exit 1
}

$len = 256
$sb = New-Object System.Text.StringBuilder $len
$rc = [W32.PInvoke]::GetPackageFullName($h, [ref]$len, $sb)
[W32.PInvoke]::CloseHandle($h) | Out-Null

# Process may still be alive on slow runners; harmless to ask it to exit.
Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue

if ($rc -ne 0) {
    # 15700 == 0x3D54 == APPMODEL_ERROR_NO_PACKAGE
    Write-Error "Firezone.exe has no package identity (GetPackageFullName rc=$rc, len=$len)"
    exit 1
}

$pfn = $sb.ToString()
Write-Output "Firezone.exe package: $pfn"
if ($pfn -notlike "Firezone.Client.GUI_*") {
    Write-Error "Firezone.exe has unexpected package family `"$pfn`""
    exit 1
}
