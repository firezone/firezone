#!/usr/bin/env bash
set -xeuo pipefail

# This is script is used to bump the versions in support of our release process.

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
# 7. Commit the changes and open a PR. Ensure the Changelog is correctly
#    updated with the changes.
function apple() {
    current_apple_version="1.4.5"
    next_apple_version="1.4.6"

    find website -type f -name "redirects.js" -exec sed "${SEDARG[@]}" -e '/mark:current-apple-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/'"${current_apple_version}"'/g;}' {} \;
    find website -type f -name "route.ts" -exec sed "${SEDARG[@]}" -e '/mark:current-apple-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/'"${current_apple_version}"'/g;}' {} \;
    find .github -type f -exec sed "${SEDARG[@]}" -e '/mark:next-apple-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/'"${next_apple_version}"'/g;}' {} \;
    find swift -type f -name "project.pbxproj" -exec sed "${SEDARG[@]}" -e "s/MARKETING_VERSION = .*;/MARKETING_VERSION = ${next_apple_version};/" {} \;
    find rust -path rust/gui-client/node_modules -prune -o -path rust/target -prune -o -name "Cargo.toml" -exec sed "${SEDARG[@]}" -e '/mark:next-apple-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/'"${next_apple_version}"'/;}' {} \;
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
# 1. Run the `Kotlin` workflow from `main`. This will push an AAB to Firebase.
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
# 7. Commit the changes and open a PR. Ensure the Changelog is correctly
#    updated with the changes.
function android() {
    current_android_version="1.4.2"
    next_android_version="1.4.3"

    find website -type f -name "redirects.js" -exec sed "${SEDARG[@]}" -e '/mark:current-android-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/'"${current_android_version}"'/g;}' {} \;
    find website -type f -name "route.ts" -exec sed "${SEDARG[@]}" -e '/mark:current-android-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/'"${current_android_version}"'/g;}' {} \;
    find .github -type f -exec sed "${SEDARG[@]}" -e '/mark:next-android-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/'"${next_android_version}"'/g;}' {} \;
    find kotlin -type f -name "*.gradle.kts" -exec sed "${SEDARG[@]}" -e '/mark:next-android-version/{n;s/versionName =.*/versionName = "'"${next_android_version}"'"/;}' {} \;
    find rust -path rust/gui-client/node_modules -prune -o -path rust/target -prune -o -name "Cargo.toml" -exec sed "${SEDARG[@]}" -e '/mark:next-android-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/'"${next_android_version}"'/;}' {} \;
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
# 5. Commit the changes and open a PR. Ensure the Changelog is correctly
#    updated with the changes.
function gui() {
    current_gui_version="1.4.7"
    next_gui_version="1.4.8"

    find website -type f -name "redirects.js" -exec sed "${SEDARG[@]}" -e '/mark:current-gui-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/'"${current_gui_version}"'/g;}' {} \;
    find website -type f -name "route.ts" -exec sed "${SEDARG[@]}" -e '/mark:current-gui-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/'"${current_gui_version}"'/g;}' {} \;
    find .github -type f -exec sed "${SEDARG[@]}" -e '/mark:next-gui-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/'"${next_gui_version}"'/g;}' {} \;
    find rust -path rust/gui-client/node_modules -prune -o -path rust/target -prune -o -name "Cargo.toml" -exec sed "${SEDARG[@]}" -e '/mark:next-gui-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/'"${next_gui_version}"'/;}' {} \;
    find rust -path rust/gui-client/node_modules -prune -o -path rust/target -prune -o -name "*.rs" -exec sed "${SEDARG[@]}" -e '/mark:next-gui-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/'"${next_gui_version}"'/;}' {} \;
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
# 4. Commit the changes and open a PR. Ensure the Changelog is correctly
#    updated with the changes.
function headless() {
    current_headless_version="1.4.3"
    next_headless_version="1.4.4"

    find website -type f -name "redirects.js" -exec sed "${SEDARG[@]}" -e '/mark:current-headless-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/'"${current_headless_version}"'/g;}' {} \;
    find website -type f -name "route.ts" -exec sed "${SEDARG[@]}" -e '/mark:current-headless-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/'"${current_headless_version}"'/g;}' {} \;
    find .github -name "*.yml" -exec sed "${SEDARG[@]}" -e '/mark:next-headless-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/'"${next_headless_version}"'/g;}' {} \;
    find rust -path rust/gui-client/node_modules -prune -o -path rust/target -prune -o -name "Cargo.toml" -exec sed "${SEDARG[@]}" -e '/mark:next-headless-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/'"${next_headless_version}"'/;}' {} \;
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
# 4. Commit the changes and open a PR. Ensure the Changelog is correctly
#    updated with the changes.
function gateway() {
    current_gateway_version="1.4.4"
    next_gateway_version="1.4.5"

    find website -type f -name "redirects.js" -exec sed "${SEDARG[@]}" -e '/mark:current-gateway-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/'"${current_gateway_version}"'/g;}' {} \;
    find website -type f -name "route.ts" -exec sed "${SEDARG[@]}" -e '/mark:current-gateway-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/'"${current_gateway_version}"'/g;}' {} \;
    find .github -type f -exec sed "${SEDARG[@]}" -e '/mark:next-gateway-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/'"${next_gateway_version}"'/g;}' {} \;
    find rust -path rust/gui-client/node_modules -prune -o -path rust/target -prune -o -name "Cargo.toml" -exec sed "${SEDARG[@]}" -e '/mark:next-gateway-version/{n;s/[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}/'"${next_gateway_version}"'/;}' {} \;
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
