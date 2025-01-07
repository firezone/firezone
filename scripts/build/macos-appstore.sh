#!/usr/bin/env bash

# Builds the Firezone macOS client for submitting to the App Store

set -euo pipefail

source "./scripts/build/lib.sh"

# Define needed variables
app_profile_id=2bf20e38-81ea-40d0-91e5-330cf58f52d9
ne_profile_id=2c683d1a-4479-451c-9ee6-ae7d4aca5c93
temp_dir="${TEMP_DIR:-$(mktemp -d)}"
package_path="$temp_dir/Firezone.pkg"
git_sha=${GITHUB_SHA:-$(git rev-parse HEAD)}
project_file=swift/apple/Firezone.xcodeproj
code_sign_identity="Apple Distribution: Firezone, Inc. (47R2M6779T)"
installer_code_sign_identity="3rd Party Mac Developer Installer: Firezone, Inc. (47R2M6779T)"

if [ "${CI:-}" = "true" ]; then
    # Configure the environment for building, signing, and packaging in CI
    setup_runner \
        "$MACOS_APP_PROVISIONING_PROFILE" \
        "$app_profile_id.provisionprofile" \
        "$MACOS_NE_PROVISIONING_PROFILE" \
        "$ne_profile_id.provisionprofile"
fi

# Build and sign
set_project_build_version "$project_file/project.pbxproj"

echo "Building and signing app..."
xcodebuild build \
    GIT_SHA="$git_sha" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$code_sign_identity" \
    CONFIGURATION_BUILD_DIR="$temp_dir" \
    APP_PROFILE_ID="$app_profile_id" \
    NE_PROFILE_ID="$ne_profile_id" \
    ONLY_ACTIVE_ARCH=NO \
    -project "$project_file" \
    -skipMacroValidation \
    -configuration Release \
    -scheme Firezone \
    -sdk macosx \
    -destination 'platform=macOS'

# Mac App Store requires a signed installer package
productbuild \
    --sign "$installer_code_sign_identity" \
    --component "$temp_dir/Firezone.app" \
    /Applications \
    "$package_path"

echo "Installer package created at $package_path"

# Move to final location the uploader expects
if [[ -n "${ARTIFACT_PATH:-}" ]]; then
    mv "$package_path" "$ARTIFACT_PATH"
fi
