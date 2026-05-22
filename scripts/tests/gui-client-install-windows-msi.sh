#!/usr/bin/env bash
# Test the MSI package, since this script is the easiest place to get a release build
set -euox pipefail

msiexec //i "$BINARY_DEST_PATH.msi" '-l*v!' install.log //qn
# Make sure the Tunnel service is running
sc query FirezoneClientTunnelService | grep RUNNING

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# `register-sparse.exe` (MSI deferred CA, runs as LocalSystem) calls
# `ProvisionPackageForAllUsersAsync`, which returns success before
# the AppX deployment service has finished syncing the package
# registration into the runner user's session. Launching
# `Firezone.exe` before that sync completes means
# `CreateProcess` doesn't see a matching registered package and
# omits the package-identity attachment, even though the package is
# present in the store. Poll `Get-AppxPackage` until the user sees
# the package before launching the GUI.
echo "==> Waiting for AppX deployment service to register the package..."
for i in $(seq 1 15); do
    PACKAGE_FOUND=$(powershell.exe -NoProfile -Command \
        "(Get-AppxPackage Firezone.Client.GUI | Select-Object -First 1).PackageFullName" \
        | tr -d '\r\n')
    if [ -n "$PACKAGE_FOUND" ]; then
        echo "==> Get-AppxPackage settled after ${i} probe(s) (~$((i * 2))s): $PACKAGE_FOUND"
        break
    fi
    sleep 2
done
if [ -z "$PACKAGE_FOUND" ]; then
    echo "Get-AppxPackage Firezone.Client.GUI returned nothing after 30s" >&2
    exit 1
fi

GUI_EXE='C:\Program Files\Firezone\Firezone.exe'

# Launch the GUI under its `debug single-instance` subcommand so
# it stays alive long enough to probe. The kernel attaches the
# package identity at `CreateProcess` time, so the identity check
# is valid as soon as we have a PID.
#
# `$!` is an MSYS2 PID; `/proc/<msys-pid>/winpid` translates it to
# the Windows PID that `OpenProcess` expects.
echo "==> Launching Firezone.exe debug single-instance..."
"$GUI_EXE" debug single-instance &
FIRST_MSYS_PID=$!
FIRST_PID=$(cat "/proc/$FIRST_MSYS_PID/winpid")
trap 'kill "$FIRST_MSYS_PID" 2>/dev/null || true' EXIT

echo "==> Verifying Firezone.exe has package identity attached..."
powershell.exe -NoProfile -File "$SCRIPT_DIR/gui-package-identity-windows.ps1" -ProcessId "$FIRST_PID"
echo "==> Package identity attached to Firezone.exe"
