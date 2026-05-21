#!/usr/bin/env bash
# Test the MSI package, since this script is the easiest place to get a release build
set -euox pipefail

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

echo "==> Verifying Firezone.exe gets package identity attached when launched..."
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
powershell.exe -NoProfile -File "$SCRIPT_DIR/check-gui-package-identity.ps1"
echo "==> Package identity attached to Firezone.exe"
