#!/usr/bin/env bash
set -euox pipefail

# Test-install the MSI package, since it already exists here
msiexec //i "$BINARY_DEST_PATH.msi" //log install.log //qn
# For debugging
cat install.log
# Make sure the Tunnel service is running
sc query FirezoneClientTunnelService | grep RUNNING

# Probe whether the sparse MSIX got registered. `Get-AppxPackage`
# settles asynchronously after `ProvisionPackageForAllUsersAsync`
# returns, so poll for up to ~30s before declaring failure. An empty
# row on supported Windows after the budget is a regression; on legacy
# Windows (build < 19044) it's expected since external-location sparse
# packages need Win10 21H2 or newer.
OS_BUILD=$(powershell.exe -NoProfile -Command \
    "[Environment]::OSVersion.Version.Build" | tr -d '\r\n')

# `Get-AppxPackage -Name X` matches against PackageFamilyName, not
# the manifest `Identity.Name`. Use the positional argument with a
# wildcard suffix so we match by family-name prefix. Poll for up to
# ~30s because the package store settles asynchronously after
# `ProvisionPackageForAllUsersAsync` returns.
KERNEL_SID=""
for i in $(seq 1 15); do
    KERNEL_SID=$(powershell.exe -NoProfile -Command \
        "(Get-AppxPackage -AllUsers Firezone.Client.GUI_* | Select-Object -First 1).Sid" \
        | tr -d '\r\n')
    if [ -n "$KERNEL_SID" ]; then
        echo "==> Get-AppxPackage settled after ${i} probe(s) (~$((i * 2))s)"
        break
    fi
    sleep 2
done

if [ -z "$KERNEL_SID" ]; then
    if [ -n "$OS_BUILD" ] && [ "$OS_BUILD" -ge 19044 ]; then
        echo "Sparse MSIX did not register on supported Windows (build $OS_BUILD ≥ 19044)" >&2
        echo "Get-AppxPackage -AllUsers Firezone.Client.GUI_* returned nothing after 30s." >&2
        echo "==> Get-AppxPackage Firezone* :" >&2
        powershell.exe -NoProfile -Command \
            "Get-AppxPackage -AllUsers Firezone* | Format-List Name, PackageFullName, PackageFamilyName, Status" >&2
        exit 1
    fi
    echo "Skipping SID canary on legacy Windows (build $OS_BUILD < 19044)"
    exit 0
fi

# SID parity: the SID is used in pipe DACLs (in a downstream PR), so
# any drift between our build-time derivation and the kernel's runtime
# value would silently break access control. A wrong PFN derivation
# also surfaces here because the SID is hashed from the lowercased
# PFN, so we don't need a separate PFN-parity check.
RUST_SID=$('/c/Program Files/Firezone/Firezone.exe' debug print-package-sid \
    | tr -d '\r\n')
if [ "$KERNEL_SID" != "$RUST_SID" ]; then
    echo "SID mismatch:" >&2
    echo "  kernel='$KERNEL_SID'" >&2
    echo "  rust  ='$RUST_SID'" >&2
    exit 1
fi
echo "Package SID parity OK: $KERNEL_SID"
