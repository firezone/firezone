#!/usr/bin/env bash

# Runs the Swift tests of `FirezoneKit`

set -euo pipefail

source "./scripts/build/lib.sh"

# Define needed variables
app_profile_id=$(extract_uuid "$MACOS_APP_PROVISIONING_PROFILE")
ne_profile_id=$(extract_uuid "$MACOS_NE_PROVISIONING_PROFILE")

if [ "${CI:-}" = "true" ]; then
    # Configure the environment for building, signing, and packaging in CI
    setup_runner \
        "$MACOS_APP_PROVISIONING_PROFILE" \
        "$app_profile_id.provisionprofile" \
        "$MACOS_NE_PROVISIONING_PROFILE" \
        "$ne_profile_id.provisionprofile"
fi

(cd swift/apple/FirezoneKit; swift test)
