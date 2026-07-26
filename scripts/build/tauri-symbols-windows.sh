#!/usr/bin/env bash
#
# Runs from `rust/gui-client`

set -euox pipefail

# Only the binaries we ship. Scanning all of `target` also picks up intermediate
# object files, whose debug info can reference a directory instead of a source
# file, which aborts the upload.
sentry-cli debug-files upload --log-level info --project gui-client --include-sources \
    "$TARGET_DIR/release/Firezone.exe" \
    "$TARGET_DIR/release/firezone_gui_client.pdb" \
    "$TARGET_DIR/release/firezone-client-tunnel.exe" \
    "$TARGET_DIR/release/firezone_client_tunnel.pdb" \
    "$TARGET_DIR/release/register-sparse.exe" \
    "$TARGET_DIR/release/register_sparse.pdb"
