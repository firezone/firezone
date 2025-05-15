#!/usr/bin/env bash
set -euox pipefail

# Test-install the MSI package, since it already exists here
msiexec //i "$BINARY_DEST_PATH.msi" //log install.log //qn
# For debugging
cat install.log
# Make sure the Tunnel service is running
sc query FirezoneClientIpcService | grep RUNNING
