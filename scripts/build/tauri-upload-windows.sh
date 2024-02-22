#!/usr/bin/env bash

set -euo pipefail

# This artifact name is tied to the update checker in `gui-client/src-tauri/src/client/updates.rs`
gh release upload "$TAG_NAME" \
    $BINARY_DEST_PATH-x64.msi \
    $BINARY_DEST_PATH-x64.msi.sha256sum.txt \
    --clobber \
    --repo "$REPOSITORY"
