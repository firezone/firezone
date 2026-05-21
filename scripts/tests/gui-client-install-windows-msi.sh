#!/usr/bin/env bash
set -euox pipefail

# Test-install the MSI package, since it already exists here. The
# install log lands in `install.log`, which the parent CI workflow
# dumps via a separate `if: always()` step so we get the verbose
# MSI trace on every run — even when `msiexec` itself returns
# non-zero.
#
# `-l*v!`: verbose log, flush after each line — picks up the
# CustomAction / Component-level detail that's missing from the
# non-verbose `/log` flag. The `-` prefix (instead of `/`) avoids
# MSYS interpreting the leading slashes as a UNC path. The single
# quotes keep bash from globbing the `*`.
msiexec //i "$BINARY_DEST_PATH.msi" '-l*v!' install.log //qn
# Make sure the Tunnel service is running
sc query FirezoneClientTunnelService | grep RUNNING

# Probe whether the sparse MSIX got registered. `Get-AppxPackage`'s
# positional filter is opaque, so pipe through `Where-Object Name -eq`
# for predictable matching. Poll for up to ~30s because the package
# store settles asynchronously after `ProvisionPackageForAllUsersAsync`
# returns.
OS_BUILD=$(powershell.exe -NoProfile -Command \
    "[Environment]::OSVersion.Version.Build" | tr -d '\r\n')

PACKAGE_FOUND=""
for i in $(seq 1 15); do
    PACKAGE_FOUND=$(powershell.exe -NoProfile -Command \
        "(Get-AppxPackage -AllUsers | Where-Object Name -eq 'Firezone.Client.GUI' | Select-Object -First 1).PackageFullName" \
        | tr -d '\r\n')
    if [ -n "$PACKAGE_FOUND" ]; then
        echo "==> Get-AppxPackage settled after ${i} probe(s) (~$((i * 2))s): $PACKAGE_FOUND"
        break
    fi
    sleep 2
done

if [ -z "$PACKAGE_FOUND" ]; then
    if [ -n "$OS_BUILD" ] && [ "$OS_BUILD" -ge 19044 ]; then
        echo "Sparse MSIX did not register on supported Windows (build $OS_BUILD ≥ 19044)" >&2
        echo "Get-AppxPackage -AllUsers (filtered by Name) returned nothing after 30s." >&2
        echo "==> Get-AppxPackage -AllUsers Firezone* (diagnostic dump):" >&2
        powershell.exe -NoProfile -Command \
            "Get-AppxPackage -AllUsers Firezone* | Format-List Name, PackageFullName, PackageFamilyName, Status" >&2
        exit 1
    fi
    echo "Skipping AppxPackage check on legacy Windows (build $OS_BUILD < 19044)"
    exit 0
fi

# Verify that the kernel actually attached the Firezone package
# identity to the running tunnel service. `Get-AppxPackage` only
# tells us the package store knows about it — that doesn't mean
# launching the bundled EXEs picks it up. Wrong `Executable=`
# paths in `AppxManifest.xml` (e.g. the classic-package
# `VFS\ProgramFilesX64\…` prefix instead of plain relative paths
# under the external location) trip *exactly* this case: package
# stages OK, process token gets no PFN.
#
# `GetPackageFullName(processHandle, ...)` returns
# `APPMODEL_ERROR_NO_PACKAGE` (`0x80073D54`) on processes without
# identity. We P/Invoke it from PowerShell against the running
# tunnel service's PID — no need to launch a process ourselves,
# the service is already up from the install transaction.
echo "==> Verifying tunnel service has package identity attached..."
powershell.exe -NoProfile -Command '
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
'
echo "==> Package identity attached to tunnel service"
