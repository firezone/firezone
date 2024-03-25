#!/usr/bin/env bash

set -euo pipefail

# This artifact name is tied to the update checker in `gui-client/src-tauri/src/client/updates.rs`
# Before publishing the deb re-check this checklist: <https://github.com/firezone/firezone/issues/3884>

#gh release upload "$TAG_NAME" \
#    "$BINARY_DEST_PATH"_amd64.deb \
#    "$BINARY_DEST_PATH"_amd64.deb.sha256sum.txt \
#    --clobber \
#    --repo "$REPOSITORY"
