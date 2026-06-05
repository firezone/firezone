# Diagnoses the Windows "Firezone finished first-time setup. Please
# start Firezone again." relaunch loop.
#
# The GUI's launch-time `ensure_package_identity` (see
# `rust/gui-client/src-tauri/src/package_identity.rs`) registers the
# sparse MSIX for the current user, then asks for a restart because
# package identity only attaches at `CreateProcess`. If the *next*
# launch still has no identity, the app loops on that dialog forever.
#
# Identity is stamped by the kernel only when ALL of these line up:
#   1. the sparse package is registered for the current user;
#   2. the running `Firezone.exe` carries the embedded `<msix>` SXS
#      claim, and its name / publisher / version / applicationId match
#      the registered package;
#   3. that external `Firezone.exe` validates against the package
#      publisher -- a tampered binary (Authenticode `HashMismatch`) is
#      refused identity even though it still runs.
# This script checks each link and prints a verdict.
#
# READ-ONLY except:
#   - the live-identity probe (default on), which briefly launches and
#     then stops `Firezone.exe`. That is the same per-user registration
#     the loop already performs; it does not change persistent state.
#     Pass -SkipLiveProbe to disable.
#   - the optional -MsiPath comparison, which extracts the MSI to a
#     temp dir via an administrative install (`msiexec /a`). It does
#     not touch the installed app.
# Safe to run while reproducing the loop.
#
# Run from an ELEVATED Windows PowerShell so the AppX event log and the
# per-user / all-users package queries return complete results.

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$InstallDir = "C:\Program Files\Firezone",
    [string]$PackageName = "Firezone.Client.GUI",
    # Path to the MSI you installed from. When set, extracts it and
    # compares the payload `Firezone.exe` signature against the
    # installed copy, to tell "shipped broken" from "tampered locally".
    [string]$MsiPath,
    # Skip the live launch + GetPackageFullName probe.
    [switch]$SkipLiveProbe
)

$ErrorActionPreference = "Continue"

$Exe = Join-Path $InstallDir "Firezone.exe"
$Msix = Join-Path $InstallDir "firezone.msix"

$script:Findings = New-Object System.Collections.Generic.List[object]
function Add-Finding([string]$Severity, [string]$Message) {
    $script:Findings.Add([pscustomobject]@{ Severity = $Severity; Message = $Message })
}
function Write-Section([string]$Title) {
    Write-Host ""
    Write-Host ("=" * 72)
    Write-Host "== $Title"
    Write-Host ("=" * 72)
}
function Normalize([string]$s) { if ($null -eq $s) { "" } else { ($s -replace '\s+', ' ').Trim() } }

# RT_MANIFEST (24) / CREATEPROCESS_MANIFEST_RESOURCE_ID (1) reader, so
# we can see the `<msix>` claim baked into the exe without the SDK.
if (-not ([System.Management.Automation.PSTypeName]'FZDiag.ManifestReader').Type) {
    Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
namespace FZDiag {
  public static class ManifestReader {
    [DllImport("kernel32", SetLastError=true, CharSet=CharSet.Unicode)] static extern IntPtr LoadLibraryEx(string f, IntPtr h, uint flags);
    [DllImport("kernel32", SetLastError=true)] static extern bool FreeLibrary(IntPtr h);
    [DllImport("kernel32", SetLastError=true)] static extern IntPtr FindResource(IntPtr h, IntPtr name, IntPtr type);
    [DllImport("kernel32", SetLastError=true)] static extern IntPtr LoadResource(IntPtr h, IntPtr res);
    [DllImport("kernel32")] static extern IntPtr LockResource(IntPtr resData);
    [DllImport("kernel32", SetLastError=true)] static extern uint SizeofResource(IntPtr h, IntPtr res);
    public static string Read(string path) {
      const uint LOAD_LIBRARY_AS_DATAFILE = 0x2;
      IntPtr h = LoadLibraryEx(path, IntPtr.Zero, LOAD_LIBRARY_AS_DATAFILE);
      if (h == IntPtr.Zero) throw new Exception("LoadLibraryEx failed: " + Marshal.GetLastWin32Error());
      try {
        IntPtr res = FindResource(h, (IntPtr)1, (IntPtr)24);
        if (res == IntPtr.Zero) return null;
        IntPtr data = LoadResource(h, res);
        uint size = SizeofResource(h, res);
        byte[] buf = new byte[size];
        Marshal.Copy(LockResource(data), buf, 0, (int)size);
        return Encoding.UTF8.GetString(buf);
      } finally { FreeLibrary(h); }
    }
  }
  public static class PkgId {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern int GetPackageFullName(IntPtr h, ref int len, StringBuilder buf);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(int desiredAccess, bool inheritHandle, int processId);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
  }
}
"@
}

Write-Host ("Firezone package-identity loop diagnostic -- {0}" -f (Get-Date))
Write-Host ("User: {0}   OS build: {1}" -f $env:USERNAME, [System.Environment]::OSVersion.Version)
Write-Host ("InstallDir: {0}" -f $InstallDir)

# 1. Installed binaries and their Authenticode signatures.
Write-Section "Installed binaries & signatures"
$exeSig = $null
if (Test-Path $Exe) {
    $exeSig = Get-AuthenticodeSignature $Exe
    $exeItem = Get-Item $Exe
    Write-Host ("Firezone.exe    : {0}" -f $Exe)
    Write-Host ("  Signature     : {0}" -f $exeSig.Status)
    if ($exeSig.StatusMessage) { Write-Host ("  StatusMessage : {0}" -f $exeSig.StatusMessage) }
    Write-Host ("  Signer        : {0}" -f $exeSig.SignerCertificate.Subject)
    Write-Host ("  Created       : {0}" -f $exeItem.CreationTime)
    Write-Host ("  LastWrite     : {0}" -f $exeItem.LastWriteTime)
    Write-Host ("  Size / SHA256 : {0} bytes / {1}" -f $exeItem.Length, (Get-FileHash $Exe -Algorithm SHA256).Hash)
    if ($exeSig.Status -ne "Valid") {
        Add-Finding "ROOT-CAUSE" ("Firezone.exe signature is '{0}', not 'Valid'. Windows refuses to attach package identity to a binary that fails its publisher signature, so every launch re-registers, asks to restart, and loops. 'HashMismatch' means the exe was modified after it was signed." -f $exeSig.Status)
        if ($exeItem.CreationTime -eq $exeItem.LastWriteTime) {
            Add-Finding "INFO" "Firezone.exe CreationTime == LastWriteTime, so nothing rewrote it after install -- the broken bytes came from the installer. Points at the build/signing pipeline (signed, then modified before packaging), not local tampering. Confirm with -MsiPath."
        } else {
            Add-Finding "INFO" "Firezone.exe LastWriteTime is later than CreationTime, so something modified it after install (AV/EDR, partial copy). Reinstall from a known-good MSI and re-check."
        }
    }
} else {
    Write-Host ("Firezone.exe    : NOT FOUND at {0}" -f $Exe)
    Add-Finding "ERROR" ("Firezone.exe not found at {0}. Pass -InstallDir if it lives elsewhere." -f $Exe)
}

if (Test-Path $Msix) {
    $msixSig = Get-AuthenticodeSignature $Msix
    Write-Host ("firezone.msix   : {0}" -f $Msix)
    Write-Host ("  Signature     : {0}" -f $msixSig.Status)
    Write-Host ("  Signer        : {0}" -f $msixSig.SignerCertificate.Subject)
    if ($msixSig.Status -ne "Valid") { Add-Finding "WARN" ("firezone.msix signature is '{0}', not 'Valid'." -f $msixSig.Status) }
} else {
    Write-Host ("firezone.msix   : NOT FOUND at {0}" -f $Msix)
}

# 2. The `<msix>` identity claim embedded in Firezone.exe.
Write-Section "Embedded SXS / fusion manifest in Firezone.exe"
$embedded = $null
$exeVer = $null; $exePkg = $null; $exeApp = $null; $exePub = $null; $hasClaim = $false
if (Test-Path $Exe) {
    try { $embedded = [FZDiag.ManifestReader]::Read($Exe) } catch { Write-Host ("  (failed to read manifest: {0})" -f $_) }
}
if ($embedded) {
    $hasClaim = $embedded -match '<msix\b'
    if ($embedded -match '(?s)<assemblyIdentity\b(?=[^>]*\bname="Firezone)[^>]*\bversion="([^"]+)"') { $exeVer = $Matches[1] }
    if ($embedded -match '<msix\b[^>]*\bpackageName="([^"]+)"')   { $exePkg = $Matches[1] }
    if ($embedded -match '<msix\b[^>]*\bapplicationId="([^"]+)"') { $exeApp = $Matches[1] }
    if ($embedded -match '<msix\b[^>]*\bpublisher="([^"]+)"')     { $exePub = ($Matches[1] -replace '&quot;', '"') }
    Write-Host ("  <msix> claim    : {0}" -f $(if ($hasClaim) { "present" } else { "ABSENT" }))
    Write-Host ("  assemblyVersion : {0}" -f $exeVer)
    Write-Host ("  packageName     : {0}" -f $exePkg)
    Write-Host ("  applicationId   : {0}" -f $exeApp)
    Write-Host ("  publisher       : {0}" -f $exePub)
    if (-not $hasClaim) {
        Add-Finding "ROOT-CAUSE" "Firezone.exe has an embedded manifest but NO <msix> claim. build.rs only embeds the claim for --profile release, so this is a non-release build; identity can never attach. Install an official release MSI."
    }
} else {
    Write-Host "  embedded RT_MANIFEST: ABSENT"
    Add-Finding "ROOT-CAUSE" "Firezone.exe carries no embedded application manifest (non-release build). Identity can never attach. Install an official release MSI."
}

# 3. The registered sparse package.
Write-Section "Registered sparse package"
$pkg = $null
try { $pkg = Get-AppxPackage -Name $PackageName -ErrorAction Stop | Select-Object -First 1 }
catch { Write-Host ("  Get-AppxPackage failed (use Windows PowerShell, elevated): {0}" -f $_) }
if ($pkg) {
    Write-Host ("  PackageFullName : {0}" -f $pkg.PackageFullName)
    Write-Host ("  Version         : {0}" -f $pkg.Version)
    Write-Host ("  InstallLocation : {0}" -f $pkg.InstallLocation)
    Write-Host ("  SignatureKind   : {0}" -f $pkg.SignatureKind)
    Write-Host ("  Status          : {0}" -f $pkg.Status)
    if ("$($pkg.Status)" -ne "Ok") { Add-Finding "WARN" ("Registered package Status is '{0}', not 'Ok'." -f $pkg.Status) }
} else {
    Write-Host "  NOT registered for the current user."
    Add-Finding "WARN" "Sparse package is not registered for the current user. The GUI registers it on first launch; if it never sticks, check the exe signature and the AppX event log below."
}
try {
    foreach ($a in (Get-AppxPackage -AllUsers -Name $PackageName -ErrorAction Stop)) {
        Write-Host ("  AllUsers        : {0}" -f $a.PackageFullName)
        foreach ($u in $a.PackageUserInformation) { Write-Host ("                    - {0}" -f $u) }
    }
} catch { Write-Host ("  (Get-AppxPackage -AllUsers needs elevation: {0})" -f $_) }
try {
    foreach ($p in (Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object DisplayName -like "Firezone*")) {
        Write-Host ("  Provisioned     : {0} ({1})" -f $p.PackageName, $p.Version)
    }
} catch { Write-Host ("  (Get-AppxProvisionedPackage needs elevation: {0})" -f $_) }

# 4. The registered package's own manifest.
Write-Section "Registered package manifest"
$regVer = $null; $regExe = $null; $regPub = $null
if ($pkg -and $pkg.InstallLocation -and (Test-Path $pkg.InstallLocation)) {
    $manifestPath = Join-Path $pkg.InstallLocation "AppxManifest.xml"
    if (Test-Path $manifestPath) {
        try {
            [xml]$m = Get-Content $manifestPath -Raw
            $regVer = $m.Package.Identity.Version
            $regPub = $m.Package.Identity.Publisher
            $regExe = $m.Package.Applications.Application.Executable
            Write-Host ("  Identity Version: {0}" -f $regVer)
            Write-Host ("  Publisher       : {0}" -f $regPub)
            Write-Host ("  Executable      : {0}" -f $regExe)
        } catch { Write-Host ("  (failed to parse AppxManifest.xml: {0})" -f $_) }
    } else { Write-Host ("  AppxManifest.xml not found at {0}" -f $manifestPath) }
} else {
    Write-Host "  (no registered package to read)"
}

# 5. Do the exe's claim and the registered package agree?
Write-Section "Cross-checks (exe claim vs. registered package)"
if ($exeVer -and $regVer) {
    if ($exeVer -eq $regVer) {
        Write-Host ("  version : exe {0} == registered {1}   [OK]" -f $exeVer, $regVer)
    } else {
        Write-Host ("  version : exe {0} != registered {1}   [MISMATCH]" -f $exeVer, $regVer)
        Add-Finding "ROOT-CAUSE" ("Version skew: Firezone.exe's <msix> claim is {0} but the registered package is {1}. The kernel can't resolve the claim, so no identity attaches and the app loops. Rebuild the installer from matched artifacts." -f $exeVer, $regVer)
    }
}
if ($exePub -and $regPub) {
    if ((Normalize $exePub) -eq (Normalize $regPub)) {
        Write-Host "  publisher : exe == registered   [OK]"
    } else {
        Write-Host "  publisher : exe != registered   [MISMATCH]"
        Add-Finding "ROOT-CAUSE" "Publisher mismatch between Firezone.exe's <msix> claim and the registered package; identity can't attach."
    }
}
if ($exeApp -and $regExe -and ($exeApp -ne "Firezone")) {
    Write-Host ("  note: exe applicationId is '{0}' (expected 'Firezone')" -f $exeApp)
}

# 6. Does a freshly launched Firezone.exe actually receive identity?
if (-not $SkipLiveProbe -and (Test-Path $Exe)) {
    Write-Section "Live identity probe (launches, then stops Firezone.exe)"
    # No --no-error-dialog: on the loop path the info dialog blocks and
    # keeps the process alive long enough to query it. We stop it after.
    $proc = $null
    try {
        $proc = Start-Process -FilePath $Exe -ArgumentList "--no-deep-links", "--no-elevation-check" -PassThru
        Start-Sleep -Milliseconds 1500
        $h = [FZDiag.PkgId]::OpenProcess(0x1000, $false, $proc.Id) # PROCESS_QUERY_LIMITED_INFORMATION
        if ($h -eq [IntPtr]::Zero) {
            Write-Host ("  OpenProcess failed (process exited too fast?), lastError={0}" -f [System.Runtime.InteropServices.Marshal]::GetLastWin32Error())
        } else {
            $len = 256
            $sb = New-Object System.Text.StringBuilder $len
            $rc = [FZDiag.PkgId]::GetPackageFullName($h, [ref]$len, $sb)
            [FZDiag.PkgId]::CloseHandle($h) | Out-Null
            if ($rc -eq 0) {
                Write-Host ("  IDENTITY ATTACHED: {0}" -f $sb.ToString())
                Add-Finding "INFO" ("A freshly launched Firezone.exe DID receive identity ({0}). If the GUI still loops, the cause is elsewhere (e.g. Package.Current / WinRT) -- capture the full GUI log." -f $sb.ToString())
            } else {
                Write-Host ("  NO IDENTITY: GetPackageFullName rc={0} (15700 = APPMODEL_ERROR_NO_PACKAGE)" -f $rc)
                Add-Finding "CONFIRMED" ("A freshly launched Firezone.exe received NO identity (rc={0}) -- the loop, confirmed at runtime." -f $rc)
            }
        }
    } catch {
        Write-Host ("  probe failed: {0}" -f $_)
    } finally {
        if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    }
}

# 7. Shipped-broken vs. tampered-locally: compare the MSI's payload.
if ($MsiPath) {
    Write-Section "MSI payload signature comparison"
    if (Test-Path $MsiPath) {
        $extract = Join-Path $env:TEMP ("fz-msi-extract-" + [guid]::NewGuid().ToString("N"))
        Write-Host ("  Extracting (administrative install, does not install): {0}" -f $MsiPath)
        $mp = Start-Process msiexec.exe -ArgumentList "/a", "`"$MsiPath`"", "TARGETDIR=`"$extract`"", "/qn" -Wait -PassThru
        if ($mp.ExitCode -ne 0) {
            Write-Host ("  msiexec /a failed with {0}" -f $mp.ExitCode)
        } else {
            foreach ($f in (Get-ChildItem -Recurse $extract -Filter Firezone.exe -ErrorAction SilentlyContinue)) {
                $s = Get-AuthenticodeSignature $f.FullName
                Write-Host ("  {0,-13} {1}" -f $s.Status, $f.FullName)
                if ($s.Status -eq "Valid") {
                    Add-Finding "INFO" ("The MSI payload Firezone.exe is validly signed but the installed copy is '{0}'. Something modified it after install (AV/EDR, bad copy). Reinstall from a known-good MSI." -f $(if ($exeSig) { $exeSig.Status } else { "?" }))
                } else {
                    Add-Finding "INFO" ("The MSI payload Firezone.exe is ALSO '{0}'. The binary is modified after signing in the build/packaging pipeline -- every install will loop. Fix the pipeline so the exe is signed last and nothing rewrites it afterward." -f $s.Status)
                }
            }
        }
        Remove-Item -Recurse -Force $extract -ErrorAction SilentlyContinue
    } else {
        Write-Host ("  -MsiPath '{0}' not found." -f $MsiPath)
    }
}

# 8. Install-time and GUI logs.
Write-Section "Logs"
$svcLogDir = Join-Path $env:PROGRAMDATA "dev.firezone.client\data\logs"
$guiLogDir = Join-Path $env:LOCALAPPDATA "dev.firezone.client\data\logs"
$rs = Get-ChildItem $svcLogDir -Filter "register-sparse*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
if ($rs) {
    Write-Host ("  register-sparse log: {0}" -f $rs.FullName)
    Get-Content $rs.FullName | Select-Object -Last 15 | ForEach-Object { Write-Host ("    {0}" -f $_) }
} else {
    Write-Host ("  no register-sparse*.log under {0}" -f $svcLogDir)
}
$gl = Get-ChildItem $guiLogDir -Filter "*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
if ($gl) {
    Write-Host ("  GUI log (identity lines): {0}" -f $gl.FullName)
    Select-String -Path $gl.FullName -Pattern "package identity|Registering Firezone package|restart is required|registration failed|APPMODEL" -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Host ("    {0}" -f $_.Line) }
} else {
    Write-Host ("  no GUI *.log under {0}" -f $guiLogDir)
}

# 9. AppX deployment service event log.
Write-Section "AppX deployment event log (recent Firezone entries)"
try {
    $evts = Get-WinEvent -LogName "Microsoft-Windows-AppXDeploymentServer/Operational" -MaxEvents 120 -ErrorAction Stop |
        Where-Object { $_.Message -match "Firezone" } | Select-Object -First 12
    if ($evts) {
        foreach ($e in $evts) {
            Write-Host ("  {0}  Id={1}  {2}" -f $e.TimeCreated, $e.Id, $e.LevelDisplayName)
            Write-Host ("      {0}" -f (($e.Message -split "`r?`n")[0]))
        }
    } else {
        Write-Host "  no recent Firezone entries"
    }
} catch {
    Write-Host ("  (couldn't read AppXDeploymentServer/Operational -- run elevated: {0})" -f $_)
}

# Verdict.
Write-Section "VERDICT"
if ($script:Findings.Count -eq 0) {
    Write-Host "  No anomaly detected by the automated checks."
    Write-Host "  Re-run elevated in Windows PowerShell and attach the full output."
    Write-Host "  If the live probe showed identity attached yet the GUI still loops,"
    Write-Host "  capture the complete GUI log for a closer look."
} else {
    foreach ($sev in @("ROOT-CAUSE", "CONFIRMED", "ERROR", "WARN", "INFO")) {
        foreach ($f in ($script:Findings | Where-Object Severity -eq $sev)) {
            Write-Host ("  [{0}] {1}" -f $f.Severity, $f.Message)
        }
    }
}
Write-Host ""
