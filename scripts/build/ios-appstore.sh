#!/usr/bin/env bash

# Builds the Firezone iOS client for submitting to the App Store

set -euo pipefail

source "./scripts/build/lib.sh"

# Define needed variables
app_profile_id=$(extract_uuid "$IOS_APP_PROVISIONING_PROFILE")
ne_profile_id=$(extract_uuid "$IOS_NE_PROVISIONING_PROFILE")
temp_dir="${TEMP_DIR:-$(mktemp -d)}"
archive_path="$temp_dir/Firezone.xcarchive"
export_options_plist_path="$temp_dir/ExportOptions.plist"
git_sha=${GITHUB_SHA:-$(git rev-parse HEAD)}
project_file=swift/apple/Firezone.xcodeproj
code_sign_identity="Apple Distribution: Firezone, Inc. (47R2M6779T)"

if [ "${CI:-}" = "true" ]; then
    # Configure the environment for building, signing, and packaging in CI
    setup_runner \
        "$IOS_APP_PROVISIONING_PROFILE" \
        "$app_profile_id.mobileprovision" \
        "$IOS_NE_PROVISIONING_PROFILE" \
        "$ne_profile_id.mobileprovision"
fi

# Build and sign app
echo "Building and signing app..."
xcodebuild archive \
    GIT_SHA="$git_sha" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$code_sign_identity" \
    APP_PROFILE_ID="$app_profile_id" \
    NE_PROFILE_ID="$ne_profile_id" \
    -project "$project_file" \
    -skipMacroValidation \
    -archivePath "$archive_path" \
    -configuration Release \
    -scheme Firezone \
    -sdk iphoneos \
    -destination 'generic/platform=iOS'

# iOS requires a separate export step; write out the export options plist
# here so we can inject the provisioning profile IDs
cat <<EOF >"$export_options_plist_path"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>dev.firezone.firezone</key>
    <string>$app_profile_id</string>

    <key>dev.firezone.firezone.network-extension</key>
    <string>$ne_profile_id</string>
  </dict>
</dict>
</plist>
EOF

# Export the archive
# -exportPath MUST be a directory; the Firezone.ipa will be written here
xcodebuild \
    -exportArchive \
    -archivePath "$archive_path" \
    -exportPath "$temp_dir" \
    -exportOptionsPlist "$export_options_plist_path"

package_path="$temp_dir/Firezone.ipa"

echo "Package created at $package_path"

# Move to final location the uploader expects
if [[ -n "${ARTIFACT_PATH:-}" ]]; then
    mv "$package_path" "$ARTIFACT_PATH"
fi
