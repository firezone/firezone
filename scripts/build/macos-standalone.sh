#!/usr/bin/env bash

# Builds the Firezone macOS client for standalone distribution

set -euo pipefail

source "./scripts/build/lib.sh"

# Define needed variables
app_profile_id=c5d97f71-de80-4dfc-80f8-d0a4393ff082
ne_profile_id=153db941-2136-4d6c-96ef-52f748521e78
notarize=${NOTARIZE:-"false"}
temp_dir="${TEMP_DIR:-$(mktemp -d)}"
dmg_dir="$temp_dir/dmg"
dmg_path="$temp_dir/Firezone.dmg"
package_path="$temp_dir/package.dmg"
git_sha=${GITHUB_SHA:-$(git rev-parse HEAD)}
project_file=swift/apple/Firezone.xcodeproj
codesign_identity="Developer ID Application: Firezone, Inc. (47R2M6779T)"

if [ "${CI:-}" = "true" ]; then
    # Configure the environment for building, signing, and packaging in CI
    setup_runner \
        "$STANDALONE_MACOS_APP_PROVISIONING_PROFILE" \
        "$app_profile_id.provisionprofile" \
        "$STANDALONE_MACOS_NE_PROVISIONING_PROFILE" \
        "$ne_profile_id.provisionprofile"
fi

# Build and sign
set_project_build_version "$project_file/project.pbxproj"

echo "Building and signing app..."
xcodebuild build \
    GIT_SHA="$git_sha" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$codesign_identity" \
    PACKET_TUNNEL_PROVIDER_SUFFIX=-systemextension \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
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

# Notarize app before embedding within disk image
if [ "$notarize" = "true" ]; then
    # Notary service expects a single file, not app bundle
    ditto -c -k "$temp_dir/Firezone.app" "$temp_dir/Firezone.zip"

    private_key_path="$temp_dir/firezone-api-key.p8"
    base64_decode "$API_KEY" "$private_key_path"

    # Submit app bundle to be notarized. Can take a few minutes.
    # Notarizes embedded app bundle as well.
    xcrun notarytool submit "$temp_dir/Firezone.zip" \
        --key "$private_key_path" \
        --key-id "$API_KEY_ID" \
        --issuer "$ISSUER_ID" \
        --wait

    # Clean up private key
    rm "$private_key_path"

    # Staple notarization ticket to app bundle
    xcrun stapler staple "$temp_dir/Firezone.app"
fi

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
    "$package_path"

# Mount disk image for customization
mount_dir=$(hdiutil attach "$package_path" -readwrite -noverify -noautoopen | grep -o "/Volumes/.*")

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
hdiutil convert "$package_path" -format UDZO -o "$dmg_path"

# Sign disk image
codesign --force --sign "$codesign_identity" "$dmg_path"

echo "Disk image created at $dmg_path"

# Move to final location the uploader expects
if [[ -n "${ARTIFACT_PATH:-}" ]]; then
    mv "$dmg_path" "$ARTIFACT_PATH"
fi
