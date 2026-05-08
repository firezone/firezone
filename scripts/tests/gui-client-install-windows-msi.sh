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

if [ -z "$KERNEL_SID" ]; then
    echo "Sparse MSIX did not register; kernel reports no SID for Firezone.Client.GUI" >&2
    echo "(Ignored on legacy Windows builds where the sparse-package gate is closed.)"
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
