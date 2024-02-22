#!/usr/bin/env bash

set -euo pipefail

# This artifact name is tied to the update checker in `gui-client/src-tauri/src/client/updates.rs`
gh release upload "$TAG_NAME" \
    "$BINARY_DEST_PATH_amd64.AppImage" \
    "$BINARY_DEST_PATH_amd64.AppImage.sha256sum.txt" \
    "$BINARY_DEST_PATH_amd64.deb" \
    "$BINARY_DEST_PATH_amd64.deb.sha256sum.txt" \
    --clobber \
    --repo "$REPOSITORY"
