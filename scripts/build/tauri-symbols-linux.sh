#!/usr/bin/env bash
#
# Runs from `rust/gui-client`

set -euox pipefail

# Only the binaries we ship. Scanning all of `target` also picks up intermediate
# object files, whose debug info can reference a directory instead of a source
# file, which aborts the upload.
sentry-cli debug-files upload --log-level info --project gui-client --include-sources \
    "$TARGET_DIR/release/firezone-client-gui" \
    "$TARGET_DIR/release/firezone-client-tunnel"
