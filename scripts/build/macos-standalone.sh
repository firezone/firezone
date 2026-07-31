#!/usr/bin/env bash

# Builds the Firezone macOS client for standalone distribution

set -euo pipefail

source "./scripts/build/lib.sh"

# Define needed variables
app_profile_id=$(extract_uuid "$STANDALONE_MACOS_APP_PROVISIONING_PROFILE")
ne_profile_id=$(extract_uuid "$STANDALONE_MACOS_NE_PROVISIONING_PROFILE")
notarize=${NOTARIZE:-"false"}
temp_dir="${TEMP_DIR:-$(mktemp -d)}"
dmg_dir="$temp_dir/dmg"
dmg_path="$temp_dir/Firezone.dmg"
staging_dmg_path="$temp_dir/staging.dmg"
staging_pkg_path="$temp_dir/staging.pkg"
git_sha=${GITHUB_SHA:-$(git rev-parse HEAD)}
project_file=swift/apple/Firezone.xcodeproj
code_sign_identity="Developer ID Application: Firezone, Inc. (47R2M6779T)"
installer_code_sign_identity="Developer ID Installer: Firezone, Inc. (47R2M6779T)"

if [ "${CI:-}" = "true" ]; then
    # Configure the environment for building, signing, and packaging in CI
    setup_runner \
        "$STANDALONE_MACOS_APP_PROVISIONING_PROFILE" \
        "$app_profile_id.provisionprofile" \
        "$STANDALONE_MACOS_NE_PROVISIONING_PROFILE" \
        "$ne_profile_id.provisionprofile"
fi

# Build and sign
echo "Building and signing app..."
seconds_since_epoch=$(date +%s)
xcodebuild build \
    GIT_SHA="$git_sha" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$code_sign_identity" \
    PACKET_TUNNEL_PROVIDER_SUFFIX=-systemextension \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    CONFIGURATION_BUILD_DIR="$temp_dir" \
    APP_PROFILE_ID="$app_profile_id" \
    NE_PROFILE_ID="$ne_profile_id" \
    ONLY_ACTIVE_ARCH=NO \
    CURRENT_PROJECT_VERSION="$seconds_since_epoch" \
    -project "$project_file" \
    -skipMacroValidation \
    -configuration Release \
    -scheme Firezone \
    -sdk macosx \
    -destination 'platform=macOS'

# We also publish a pkg file for MDMs that don't like our DMG (Intune error 0x87D30139)
productbuild \
    --sign "$installer_code_sign_identity" \
    --component "$temp_dir/Firezone.app" \
    /Applications \
    "$staging_pkg_path"

# Create disk image
mkdir -p "$dmg_dir/.background"
mv "$temp_dir/Firezone.app" "$dmg_dir/Firezone.app"
cp "scripts/build/dmg_background.png" "$dmg_dir/.background/background.png"
ln -s /Applications "$dmg_dir/Applications"
hdiutil create \
    -volname "Firezone Installer" \
    -srcfolder "$dmg_dir" \
    -ov \
    -format UDRW \
    "$staging_dmg_path"

# Mount disk image for customization
mount_dir=$(hdiutil attach "$staging_dmg_path" -readwrite -noverify -noautoopen | grep -o "/Volumes/.*")

# Embed background image to instruct user to drag app to /Applications
osascript <<EOF
tell application "Finder"
    tell disk "Firezone Installer"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {100, 100, 800, 400}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set background picture of viewOptions to file ".background:background.png"
        set position of item "Firezone.app" of container window to {200, 128}
        set position of item "Applications" of container window to {500, 128}
        close
        open
        update without registering applications
        delay 2
    end tell
end tell
EOF

# Unmount disk image
hdiutil detach "$mount_dir"

# Convert to read-only
hdiutil convert "$staging_dmg_path" -format UDZO -o "$dmg_path"

# Sign disk image
codesign --force --sign "$code_sign_identity" "$dmg_path"

echo "Disk image created at $dmg_path"

# Notarize disk image and package installer; notarizes embedded app bundle as well
if [ "$notarize" = "true" ]; then
    private_key_path="$temp_dir/firezone-api-key.p8"
    base64_decode "$API_KEY" "$private_key_path"

    # Submit both DMG and PKG in parallel (each can take several minutes)
    echo "Submitting DMG and PKG for notarization in parallel..."

    xcrun notarytool submit "$dmg_path" \
        --key "$private_key_path" \
        --key-id "$API_KEY_ID" \
        --issuer "$ISSUER_ID" \
        --wait &
    dmg_pid=$!

    xcrun notarytool submit "$staging_pkg_path" \
        --key "$private_key_path" \
        --key-id "$API_KEY_ID" \
        --issuer "$ISSUER_ID" \
        --wait &
    pkg_pid=$!

    # Wait for both notarization jobs to complete
    dmg_exit=0
    pkg_exit=0
    wait $dmg_pid || dmg_exit=$?
    wait $pkg_pid || pkg_exit=$?

    if [ $dmg_exit -ne 0 ]; then
        echo "DMG notarization failed with exit code $dmg_exit"
        rm "$private_key_path"
        exit $dmg_exit
    fi

    if [ $pkg_exit -ne 0 ]; then
        echo "PKG notarization failed with exit code $pkg_exit"
        rm "$private_key_path"
        exit $pkg_exit
    fi

    # Staple and verify both (these are fast, sequential is fine)
    xcrun stapler staple "$dmg_path"
    xcrun stapler validate "$dmg_path"
    echo "Disk image notarized!"

    xcrun stapler staple "$staging_pkg_path"
    xcrun stapler validate "$staging_pkg_path"

    echo "Installer PKG notarized!"

    # Clean up private key
    rm "$private_key_path"
fi

# Move to final location the uploader expects
if [[ -n "${ARTIFACT_PATH:-}" ]]; then
    mv "$dmg_path" "$ARTIFACT_PATH"

    echo "Moved DMG to $ARTIFACT_PATH"
fi
if [[ -n "${PKG_ARTIFACT_PATH:-}" ]]; then
    mv "$staging_pkg_path" "$PKG_ARTIFACT_PATH"

    echo "Moved PKG to $PKG_ARTIFACT_PATH"
fi
