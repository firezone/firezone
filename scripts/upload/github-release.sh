#!/usr/bin/env bash

# Uploads built packages to a GitHub release

set -euo pipefail

# Only clobber existing release assets if the release is a draft
is_draft=$(gh release view "$RELEASE_NAME" --json isDraft --jq '.isDraft' | tr -d '\n')
if [[ "$is_draft" == "true" ]]; then
    clobber="--clobber"
else
    clobber=""
fi

sha256sum "$ARTIFACT_PATH" >"$ARTIFACT_PATH.sha256sum.txt"

gh release upload "$RELEASE_NAME" \
    "$ARTIFACT_PATH" \
    "$ARTIFACT_PATH.sha256sum.txt" \
    $clobber \
    --repo "$GITHUB_REPOSITORY"
