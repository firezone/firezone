# Upgrades the latest released MSI to the one built here and checks that the
# upgrade replaced the released product instead of installing next to it.
# Runs after `gui-client-install-windows-msi.ps1`, so it starts by removing
# the build that test installed.

$ErrorActionPreference = "Stop"

function Invoke-Msiexec {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $Arguments -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) {
        Write-Error "msiexec $Arguments exited with $($proc.ExitCode)"
        exit 1
    }
}

function Get-InstalledFirezone {
    Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" |
        Where-Object { $_.DisplayName -eq "Firezone" }
}

$msi = (Resolve-Path "$($env:BINARY_DEST_PATH).msi").Path

Write-Output "==> Uninstalling the build under test..."
Invoke-Msiexec "/x", "`"$msi`"", "/qn"

# Filtered here rather than with `--jq`: Windows PowerShell strips the double
# quotes a jq string literal needs from native command arguments.
$releases = (gh api "repos/$env:GITHUB_REPOSITORY/releases?per_page=100") -join "`n" | ConvertFrom-Json
$tag = ($releases | Where-Object { -not $_.draft -and $_.tag_name -like "gui-client-*" } | Select-Object -First 1).tag_name
if (-not $tag) {
    Write-Error "No published GUI client release found"
    exit 1
}
$version = $tag -replace '^gui-client-', ''
$released = "${env:RUNNER_TEMP}\firezone-client-gui-windows_${version}_${env:ARCH}.msi"
Write-Output "==> Installing the released $version..."
Invoke-WebRequest -Uri "https://github.com/$env:GITHUB_REPOSITORY/releases/download/$tag/$(Split-Path -Leaf $released)" -OutFile $released -UseBasicParsing
Invoke-Msiexec "/i", "`"$released`"", "/qn"

Write-Output "==> Upgrading to the build under test..."
Invoke-Msiexec "/i", "`"$msi`"", "/l*v!", "upgrade.log", "/qn"

$installed = @(Get-InstalledFirezone)
$installed | Format-List DisplayName, DisplayVersion, PSChildName
if ($installed.Count -ne 1) {
    Write-Error "Expected one installed Firezone product after the upgrade, found $($installed.Count)"
    exit 1
}
if ($installed[0].DisplayVersion -ne $env:FIREZONE_GUI_VERSION) {
    Write-Error "Expected version $env:FIREZONE_GUI_VERSION after the upgrade, found $($installed[0].DisplayVersion)"
    exit 1
}

foreach ($file in "Firezone.exe", "firezone-client-tunnel.exe", "register-sparse.exe", "firezone.msix", "cli\firezone.exe") {
    if (-not (Test-Path -LiteralPath "C:\Program Files\Firezone\$file")) {
        Write-Error "$file is missing after the upgrade"
        exit 1
    }
}

$null = sc.exe query FirezoneClientTunnelService | Select-String "RUNNING"
if ($LASTEXITCODE -ne 0) {
    Write-Error "FirezoneClientTunnelService is not running after the upgrade"
    exit 1
}
Write-Output "==> Upgraded in place"
