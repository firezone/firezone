#!/usr/bin/env bash
set -euox pipefail

# Test-install the MSI package, since it already exists here
msiexec //i "$BINARY_DEST_PATH.msi" //log install.log //qn
# For debugging
cat install.log
# Make sure the Tunnel service is running
sc query FirezoneClientTunnelService | grep RUNNING

# Verify the build-time-baked Package Family Name matches what the
# Windows kernel records for the registered sparse MSIX. A mismatch
# means the `register-sparse.exe` custom action provisioned a
# different identity than `firezone-gui-client` expects to reference
# at runtime — silently breaking any code path keyed on the PFN.
KERNEL_PFN=$(powershell.exe -NoProfile -Command \
    "(Get-AppxPackage -AllUsers -Name Firezone.Client.GUI | Select-Object -First 1).PackageFamilyName" \
    | tr -d '\r\n')

# Sparse-MSIX external-location packages need Win10 21H2 (build 19044)
# or newer. On runners below that floor `AddPackageByUriAsync` fails
# silently and Get-AppxPackage returns nothing. CI runs on
# windows-2022/2025 (build numbers well past 19044) so an empty PFN
# there is a real regression we want to catch loudly.
OS_BUILD=$(powershell.exe -NoProfile -Command \
    "[Environment]::OSVersion.Version.Build" | tr -d '\r\n')

# Empty PFN on supported Windows = registration regression. On legacy
# Windows (build < 19044), `AddPackageByUriAsync` fails silently — we
# skip the rest of the canary because the runtime DACL builder also
# falls back to the legacy `BU` ACE there. Either way, this branch
# exits early; the parity checks below assume KERNEL_PFN is set.
if [ -z "$KERNEL_PFN" ]; then
    if [ -n "$OS_BUILD" ] && [ "$OS_BUILD" -ge 19044 ]; then
        echo "Sparse MSIX did not register on supported Windows (build $OS_BUILD ≥ 19044)" >&2
        echo "kernel reports no PFN for Firezone.Client.GUI; this is a regression." >&2
        exit 1
    fi
    echo "Skipping PFN/SID canary on legacy Windows (build $OS_BUILD < 19044)"
    exit 0
fi

# PFN parity: build-time `PACKAGE_FAMILY_NAME` vs kernel-reported.
RUST_PFN=$('/c/Program Files/Firezone/Firezone.exe' debug print-package-family-name \
    | tr -d '\r\n')
if [ "$KERNEL_PFN" != "$RUST_PFN" ]; then
    echo "PFN mismatch:" >&2
    echo "  kernel='$KERNEL_PFN'" >&2
    echo "  rust  ='$RUST_PFN'" >&2
    exit 1
fi
echo "Package Family Name parity OK: $KERNEL_PFN"

# SID parity: a downstream PR uses the SID in pipe DACLs, so any
# drift between the build-time derivation and the kernel's runtime
# value would silently break access control. Fail loudly here.
KERNEL_SID=$(powershell.exe -NoProfile -Command \
    "(Get-AppxPackage -AllUsers -Name Firezone.Client.GUI | Select-Object -First 1).Sid" \
    | tr -d '\r\n')
RUST_SID=$('/c/Program Files/Firezone/Firezone.exe' debug print-package-sid \
    | tr -d '\r\n')
if [ "$KERNEL_SID" != "$RUST_SID" ]; then
    echo "SID mismatch:" >&2
    echo "  kernel='$KERNEL_SID'" >&2
    echo "  rust  ='$RUST_SID'" >&2
    exit 1
fi
echo "Package SID parity OK: $KERNEL_SID"
