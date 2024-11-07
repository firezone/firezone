#!/usr/bin/env bash

set -euox pipefail

# This artifact name is tied to the update checker in `gui-client/src-tauri/src/client/updates.rs`

# Only clobber existing release assets if the release is a draft
is_draft=$(gh release view "$TAG_NAME" --json isDraft --jq '.isDraft' | tr -d '\n')
if [[ "$is_draft" == "true" ]]; then
    clobber="--clobber"
else
    clobber=""
fi

gh release upload "$TAG_NAME" \
    "$BINARY_DEST_PATH".deb \
    "$BINARY_DEST_PATH".deb.sha256sum.txt \
    "$BINARY_DEST_PATH".rpm \
    "$BINARY_DEST_PATH".rpm.sha256sum.txt \
    $clobber \
    --repo "$REPOSITORY"
