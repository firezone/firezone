#!/usr/bin/env bash
set -euox pipefail

# Test-install the MSI package, since it already exists here
msiexec //i "$BINARY_DEST_PATH.msi" //log install.log //qn
# For debugging
cat install.log
# Make sure the Tunnel service is running
sc query FirezoneClientTunnelService | grep RUNNING

# Verify the build-time-baked PACKAGE_SID matches what the Windows
# kernel reports for the registered sparse MSIX. If they diverge the
# pipe DACLs in `ipc/windows.rs` will reject the legitimate clients,
# silently breaking IPC. The canary fails loudly instead.
KERNEL_SID=$(powershell.exe -NoProfile -Command \
    "(Get-AppxPackage -AllUsers -Name Firezone.Client.GUI | Select-Object -First 1).Sid" \
    | tr -d '\r\n')

# Sparse-MSIX external-location packages need Win10 21H2 (build 19044)
# or newer. On runners below that floor `AddPackageByUriAsync` fails
# and the runtime SDDL builder falls back to the legacy `BU` ACE; we
# tolerate an empty `KERNEL_SID` only in that case. CI runs on
# windows-2022/2025 (build numbers well past 19044), so an empty SID
# there is a real regression: registration failed silently, IPC will
# regress to the legacy DACL, and we want CI to catch it.
OS_BUILD=$(powershell.exe -NoProfile -Command \
    "[Environment]::OSVersion.Version.Build" | tr -d '\r\n')

if [ -z "$KERNEL_SID" ]; then
    if [ -n "$OS_BUILD" ] && [ "$OS_BUILD" -ge 19044 ]; then
        echo "Sparse MSIX did not register on supported Windows (build $OS_BUILD ≥ 19044)" >&2
        echo "kernel reports no SID for Firezone.Client.GUI; this is a regression." >&2
        exit 1
    fi
    echo "Skipping SID canary on legacy Windows (build $OS_BUILD < 19044)"
else
    RUST_SID=$('/c/Program Files/Firezone/Firezone.exe' debug print-package-sid \
        | tr -d '\r\n')
    if [ "$KERNEL_SID" != "$RUST_SID" ]; then
        echo "SID mismatch:" >&2
        echo "  kernel='$KERNEL_SID'" >&2
        echo "  rust  ='$RUST_SID'" >&2
        exit 1
    fi
    echo "Package SID parity OK: $KERNEL_SID"
fi
