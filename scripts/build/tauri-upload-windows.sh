#!/usr/bin/env bash

set -euox pipefail

# Only clobber existing release assets if the release is a draft
is_draft=$(gh release view "$TAG_NAME" --json isDraft --jq '.isDraft' | tr -d '\n')
if [[ "$is_draft" == "true" ]]; then
    clobber="--clobber"
else
    clobber=""
fi

# This artifact name is tied to the update checker in `gui-client/src-tauri/src/client/updates.rs`
# So we can't put the version number in it until we stop using Github for update checks.
gh release upload "$TAG_NAME" \
    "$BINARY_DEST_PATH".msi \
    "$BINARY_DEST_PATH".msi.sha256sum.txt \
    $clobber \
    --repo "$REPOSITORY"
