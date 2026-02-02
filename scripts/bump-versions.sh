#!/usr/bin/env bash
set -xeuo pipefail

# This script is used to bump the versions in support of our release process.

# See discussion here: https://github.com/firezone/firezone/issues/2041
# and PR changing it here: https://github.com/firezone/firezone/pull/2949

# macOS uses a slightly different sed syntax
if [ "$(uname)" = "Darwin" ]; then
    SEDARG=(-i '')
else
    SEDARG=(-i)
fi

function cargo_update_workspace() {
    pushd rust >/dev/null
    cargo update --workspace
    popd >/dev/null
}

function update_changelog() {
    local changelog_file="$1"
    local current_version="$2"
    local current_date
    current_date=$(date +%Y-%m-%d)

    # Be idempotent: Do nothing if we already have a changelog entry for this version.
    if grep -q "<Entry version=\"${current_version}\"" "$changelog_file"; then
        return
    fi

    # Replace the <Unreleased> section with an <Entry> for the current version
    sed "${SEDARG[@]}" -e "
        s|<Unreleased>|<Entry version=\"${current_version}\" date={new Date(\"${current_date}\")}>|g;
        s|</Unreleased>|</Entry>|g;
    " "$changelog_file"

    # Add a new empty <Unreleased> section above the newly added <Entry>
    sed "${SEDARG[@]}" -e "
      /<Entry version=\"${current_version}\"/i\\
      <Unreleased></Unreleased>
    " "$changelog_file"
}

function update_version_marker() {
    local marker="$1"
    local new_version="$2"

    # Use git grep to find files containing the marker (much faster and git-aware)
    git grep -l "$marker" 2>/dev/null | while IFS= read -r file; do
        sed "${SEDARG[@]}" -e "/${marker}/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/${new_version}/g;}" "$file"
    done
}

function update_version_variables() {
    local COMPONENT="$1"
    local NEW_VERSION="$2"

    path_to_self=$(readlink -f "$0")
    current_version_variable="current_${COMPONENT//-/_}_version"
    next_version_variable="next_${COMPONENT//-/_}_version"

    IFS='.' read -r -a version_parts <<<"$NEW_VERSION"
    MAJOR="${version_parts[0]}"
    MINOR="${version_parts[1]}"
    PATCH="${version_parts[2]}"

    # Increment patch version
    NEXT_PATCH=$((PATCH + 1))
    NEXT_VERSION="$MAJOR.$MINOR.$NEXT_PATCH"

    sed "${SEDARG[@]}" "s/$current_version_variable=\"[0-9]\+\.[0-9]\+\.[0-9]\+\"/$current_version_variable=\"${NEW_VERSION}\"/" "$path_to_self"
    sed "${SEDARG[@]}" "s/$next_version_variable=\"[0-9]\+\.[0-9]\+\.[0-9]\+\"/$next_version_variable=\"${NEXT_VERSION}\"/" "$path_to_self"
}

# macOS / iOS
#
# There are 3 distributables we ship for Apple platforms:
# - macOS standalone
# - macOS app store
# - iOS app store
#
# The versioning among them are currently coupled together, such that if a
# release for one is rejected by app review, it impacts the remaining ones.
#
# As such, it's a good idea to make sure both app store releases are approved
# before publishing the macOS standalone release.
#
# Instructions:
# 1. Run the `Swift` workflow from `main`. This will push iOS and macOS app
#    store builds to AppStore Connect and upload a new standalone DMG to the
#    drafted release.
# 2. Sign in to AppStore Connect and create new iOS and macOS releases and
#    submit them for review. Ensure the "automatically publish release" is
#    DISABLED.
# 3. Once *both* are approved, publish them in the app stores.
# 4. Publish the macOS standalone drafted release on GitHub.
# 5. Come back here and bump the current and next versions.
# 6. Run `scripts/bump-versions.sh apple` to update the versions in the codebase.
# 7. Commit the changes and open a PR.
function apple() {
    current_apple_client_version="1.5.13"
    next_apple_client_version="1.5.14"

    update_changelog "website/src/components/Changelog/Apple.tsx" "$current_apple_client_version"
    update_version_marker "mark:current-apple-version" "$current_apple_client_version"
    update_version_marker "mark:next-apple-version" "$next_apple_client_version"

    cargo_update_workspace
}

# Android / ChromeOS
#
# We support Android and ChromeOS with a single build. There are two
# distributables we ship:
#
# - AAB for the Play Store
# - APK for standalone distribution
#
# As such, the process for releasing Android is similar to Apple.
#
# Instructions:
# 1. Run the `Kotlin` workflow from `main`. This will push an AAB to Firebase
#    and upload a new APK to the drafted release.
# 2. Sign in to Firebase and download the build AAB, optionally distributing it
#    for release testing to perform any final QA tests.
# 3. Sign in to the Play Console and create a new release and submit it for
#    review. Optionally, allow the Play Console to automatically publish the
#    release.
# 4. Once the Play Store release is approved, publish the APK in the drafted
#    release on GitHub.
# 5. Come back here and bump the current and next versions.
# 6. Run `scripts/bump-versions.sh android` to update the versions in the codebase.
# 7. Commit the changes and open a PR.
function android() {
    current_android_client_version="1.5.8"
    next_android_client_version="1.5.9"

    update_changelog "website/src/components/Changelog/Android.tsx" "$current_android_client_version"
    update_version_marker "mark:current-android-version" "$current_android_client_version"
    update_version_marker "mark:next-android-version" "$next_android_client_version"

    cargo_update_workspace
}

# Windows / Linux GUI
#
# We support Windows and Linux with a single build workflow.
#
# Instructions:
# 1. Run the `Tauri` workflow from `main`. This will push new release assets to
#    the drafted release on GitHub.
# 2. Perform any final QA testing on the new release assets, then publish the
#    release.
# 3. Come back here and bump the current and next versions.
# 4. Run `scripts/bump-versions.sh gui` to update the versions in the codebase.
# 5. Commit the changes and open a PR.
function gui() {
    current_gui_client_version="1.5.10"
    next_gui_client_version="1.5.11"

    update_changelog "website/src/components/Changelog/GUI.tsx" "$current_gui_client_version"
    update_version_marker "mark:current-gui-version" "$current_gui_client_version"
    update_version_marker "mark:next-gui-version" "$next_gui_client_version"

    cargo_update_workspace
}

# Windows / Linux Headless
#
# Unlike the Apple, Android, and GUI clients, headless binaries for Windows and
# Linux are built on each `main` workflow.
#
# Instructions:
# 1. Perform any final QA testing on the new release assets, then publish the
#    drafted release.
# 2. Come back here and bump the current and next versions.
# 3. Run `scripts/bump-versions.sh headless` to update the versions in the codebase.
# 4. Commit the changes and open a PR.
function headless() {
    current_headless_client_version="1.5.6"
    next_headless_client_version="1.5.7"

    update_changelog "website/src/components/Changelog/Headless.tsx" "$current_headless_client_version"
    update_version_marker "mark:current-headless-version" "$current_headless_client_version"
    update_version_marker "mark:next-headless-version" "$next_headless_client_version"

    cargo_update_workspace
}

# Gateway
#
# Unlike the Apple, Android, and GUI clients, gateway binaries for Linux are
# built on each `main` workflow.
#
# Instructions:
# 1. Perform any final QA testing on the new release assets, then publish the
#    drafted release.
# 2. Come back here and bump the current and next versions.
# 3. Run `scripts/bump-versions.sh gateway` to update the versions in the codebase.
# 4. Commit the changes and open a PR.
function gateway() {
    current_gateway_version="1.4.19"
    next_gateway_version="1.5.0"

    update_changelog "website/src/components/Changelog/Gateway.tsx" "$current_gateway_version"
    update_version_marker "mark:current-gateway-version" "$current_gateway_version"
    update_version_marker "mark:next-gateway-version" "$next_gateway_version"

    cargo_update_workspace
}

function version() {
    apple
    android
    gui
    headless
    gateway
}

if [ "$#" -eq 0 ]; then
    version
else
    "$@"
fi
