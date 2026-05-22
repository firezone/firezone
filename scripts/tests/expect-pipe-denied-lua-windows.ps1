# Open the given Windows named pipe under a LUA-filtered token --
# the same restricted token UAC hands non-elevated apps -- and
# assert that `CreateFileW` fails with `ACCESS_DENIED`. Catches DACL
# regressions where the pipe grants access to `BUILTIN\Users` (or
# anything else a typical non-admin caller is in), letting any
# same-user process drive it.
#
# Spawning an unelevated child in CI is awkward (no interactive
# desktop, no `runas` keychain), so we drop privileges in-process:
# `CreateRestrictedToken(LUA_TOKEN)` builds the same filtered token
# UAC produces (Administrators becomes deny-only, integrity drops
# to Medium); `ImpersonateLoggedOnUser` installs it on the current
# thread; the kernel then performs the named-pipe access check
# against the impersonation token.
#
# Safe against single-client pipes like `debug single-instance`:
# the kernel performs the DACL check *before* the server's
# `ConnectNamedPipe` returns, so a denied open never consumes the
# accept slot.

param(
    [Parameter(Mandatory)]
    [string]$PipePath
)

$ErrorActionPreference = "Stop"

Add-Type -MemberDefinition @"
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern IntPtr CreateFileW(
    string lpFileName, uint dwDesiredAccess, uint dwShareMode,
    IntPtr lpSecurityAttributes, uint dwCreationDisposition,
    uint dwFlagsAndAttributes, IntPtr hTemplateFile);

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool CloseHandle(IntPtr hObject);

[DllImport("advapi32.dll", SetLastError = true)]
public static extern bool OpenProcessToken(
    IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);

[DllImport("advapi32.dll", SetLastError = true)]
public static extern bool CreateRestrictedToken(
    IntPtr ExistingTokenHandle, uint Flags,
    uint DisableSidCount, IntPtr SidsToDisable,
    uint DeletePrivilegeCount, IntPtr PrivilegesToDelete,
    uint RestrictedSidCount, IntPtr SidsToRestrict,
    out IntPtr NewTokenHandle);

[DllImport("advapi32.dll", SetLastError = true)]
public static extern bool ImpersonateLoggedOnUser(IntPtr hToken);

[DllImport("advapi32.dll", SetLastError = true)]
public static extern bool RevertToSelf();

[DllImport("kernel32.dll")]
public static extern IntPtr GetCurrentProcess();
"@ -Name PipeProbe -Namespace W32

$READ_CONTROL = 0x20000
$OPEN_EXISTING = 3
$INVALID_HANDLE = [IntPtr]::new(-1)
$ERROR_FILE_NOT_FOUND = 2
$ERROR_ACCESS_DENIED = 5
$TOKEN_DUPLICATE_QUERY = 0x0A  # TOKEN_DUPLICATE (0x2) | TOKEN_QUERY (0x8)
$LUA_TOKEN = 0x4

$procToken = [IntPtr]::Zero
if (-not [W32.PipeProbe]::OpenProcessToken(
    [W32.PipeProbe]::GetCurrentProcess(), $TOKEN_DUPLICATE_QUERY, [ref]$procToken)) {
    $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    Write-Error "OpenProcessToken failed (err=$err)"
    exit 1
}

$luaToken = [IntPtr]::Zero
$ok = [W32.PipeProbe]::CreateRestrictedToken(
    $procToken, $LUA_TOKEN, 0, [IntPtr]::Zero, 0, [IntPtr]::Zero,
    0, [IntPtr]::Zero, [ref]$luaToken
)
[W32.PipeProbe]::CloseHandle($procToken) | Out-Null
if (-not $ok) {
    $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    Write-Error "CreateRestrictedToken failed (err=$err)"
    exit 1
}

if (-not [W32.PipeProbe]::ImpersonateLoggedOnUser($luaToken)) {
    $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    [W32.PipeProbe]::CloseHandle($luaToken) | Out-Null
    Write-Error "ImpersonateLoggedOnUser failed (err=$err)"
    exit 1
}

# Under the LUA-filtered token, `BUILTIN\Administrators` is
# deny-only and we don't carry the package SID, so the only
# possible match is the `LocalSystem` ACE (we aren't), leaving us
# with `ERROR_ACCESS_DENIED`. The pipe server may still be coming
# up (single-instance binds the GUI pipe after process start), so
# retry while `CreateFileW` returns `ERROR_FILE_NOT_FOUND`. A
# denied open does not consume the server's accept slot.
$h = $INVALID_HANDLE
$lastError = 0
for ($i = 0; $i -lt 50; $i++) {
    $h = [W32.PipeProbe]::CreateFileW(
        $PipePath, $READ_CONTROL, 0, [IntPtr]::Zero, $OPEN_EXISTING, 0, [IntPtr]::Zero
    )
    $lastError = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    if ($h -ne $INVALID_HANDLE -or $lastError -ne $ERROR_FILE_NOT_FOUND) { break }
    Start-Sleep -Milliseconds 100
}

[W32.PipeProbe]::RevertToSelf() | Out-Null
[W32.PipeProbe]::CloseHandle($luaToken) | Out-Null

if ($h -ne $INVALID_HANDLE) {
    [W32.PipeProbe]::CloseHandle($h) | Out-Null
    Write-Error "${PipePath} accepted a LUA-filtered open -- DACL did not pin access"
    exit 1
}

if ($lastError -ne $ERROR_ACCESS_DENIED) {
    Write-Error "expected ERROR_ACCESS_DENIED ($ERROR_ACCESS_DENIED) opening ${PipePath} under LUA token; got err=$lastError"
    exit 1
}

Write-Output "${PipePath} correctly denied non-Firezone-signed (LUA-filtered) open (err=$lastError ERROR_ACCESS_DENIED)"
