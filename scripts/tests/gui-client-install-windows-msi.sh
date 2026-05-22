#!/usr/bin/env bash
# Test the MSI package, since this script is the easiest place to get a release build
set -euox pipefail

msiexec //i "$BINARY_DEST_PATH.msi" '-l*v!' install.log //qn
# Make sure the Tunnel service is running
sc query FirezoneClientTunnelService | grep RUNNING

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

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
