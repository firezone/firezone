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

# Version source of truth. These are managed by `update_version_variables`
# (invoked from scripts/open-version-bump-pr.sh during a release) and consumed by
# the bump (`version`).
current_apple_client_version="1.5.17"
next_apple_client_version="1.5.18"
current_android_client_version="1.5.11"
next_android_client_version="1.5.12"
current_gui_client_version="1.5.13"
next_gui_client_version="1.5.14"
current_headless_client_version="1.5.9"
next_headless_client_version="1.5.10"
current_gateway_version="1.5.2"
next_gateway_version="1.5.3"

function cargo_update_workspace() {
    pushd rust >/dev/null
    cargo update --workspace
    popd >/dev/null
}

# Update a `mark:`-annotated version, searching tracked files in this repo.
function update_version_marker() {
    local marker="$1"
    local new_version="$2"

    # Use git grep to find files containing the marker (much faster and git-aware)
    git grep -l "$marker" 2>/dev/null | while IFS= read -r file; do
        sed "${SEDARG[@]}" -e "/${marker}/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/${new_version}/g;}" "$file"
    done
}

function update_gateway_checksum_marker() {
    local marker="$1"
    local checksum="$2"
    local file="$3"

    sed "${SEDARG[@]}" -e "/${marker}/{n;s/[0-9a-f]\{64\}/${checksum}/g;}" "$file"
}

function update_gateway_checksums() {
    local version="$1"
    local x86_64_checksum="$2"
    local aarch64_checksum="$3"
    local armv7_checksum="$4"
    local installer="scripts/gateway-systemd-install.sh"

    for checksum in "$x86_64_checksum" "$aarch64_checksum" "$armv7_checksum"; do
        if [[ ! "$checksum" =~ ^[0-9a-f]{64}$ ]]; then
            echo "Invalid gateway checksum for $version: $checksum" >&2
            exit 1
        fi
    done

    update_gateway_checksum_marker "mark:gateway-x86_64-sha256" "$x86_64_checksum" "$installer"
    update_gateway_checksum_marker "mark:gateway-aarch64-sha256" "$aarch64_checksum" "$installer"
    update_gateway_checksum_marker "mark:gateway-armv7-sha256" "$armv7_checksum" "$installer"
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
# 5. Bump current_apple_client_version / next_apple_client_version at the top
#    of this script (the release pipeline does this automatically via
#    `update_version_variables`).
# 6. Run `scripts/bump-versions.sh apple` to update the versions in the codebase.
# 7. Commit the changes and open a PR.
function apple() {
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
# 5. Bump current_android_client_version / next_android_client_version at the
#    top of this script (the release pipeline does this automatically via
#    `update_version_variables`).
# 6. Run `scripts/bump-versions.sh android` to update the versions in the codebase.
# 7. Commit the changes and open a PR.
function android() {
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
# 3. Bump current_gui_client_version / next_gui_client_version at the top of
#    this script (the release pipeline does this automatically via
#    `update_version_variables`).
# 4. Run `scripts/bump-versions.sh gui` to update the versions in the codebase.
# 5. Commit the changes and open a PR.
function gui() {
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
# 2. Bump current_headless_client_version / next_headless_client_version at the
#    top of this script (the release pipeline does this automatically via
#    `update_version_variables`).
# 3. Run `scripts/bump-versions.sh headless` to update the versions in the codebase.
# 4. Commit the changes and open a PR.
function headless() {
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
# 2. Bump current_gateway_version / next_gateway_version at the top of this
#    script (the release pipeline does this automatically via
#    `update_version_variables`).
# 3. Run `scripts/bump-versions.sh gateway` to update the versions in the codebase.
# 4. Commit the changes and open a PR.
function gateway() {
    update_version_marker "mark:current-gateway-version" "$current_gateway_version"
    update_version_marker "mark:next-gateway-version" "$next_gateway_version"

    cargo_update_workspace
}

# Bump versions across the monorepo (product version markers + Cargo.lock).
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
