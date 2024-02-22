#!/usr/bin/env bash
set -euo pipefail

# For debugging
ls ../target/release ../target/release/bundle/appimage ../target/release/bundle/deb

# Used for release artifact
# In release mode the name comes from tauri.conf.json
# Using a glob for the source, there will only be one exe, AppImage, and deb anyway
cp ../target/release/firezone "$BINARY_DEST_PATH"-amd64
cp ../target/release/bundle/appimage/*_amd64.AppImage "$BINARY_DEST_PATH"_amd64.AppImage
cp ../target/release/bundle/deb/*_amd64.deb "$BINARY_DEST_PATH"_amd64.deb
# TODO: Debug symbols for Linux

# I think we agreed in standup to just match platform conventions
# Firezone for Windows is "-x64" which I believe is Visual Studio's convention
# Debian calls it "amd64". Rust and Linux call it "x86_64". So whatever, it's
# amd64 here. They're all the same.
sha256sum "$BINARY_DEST_PATH"-amd64> "$BINARY_DEST_PATH"-amd64.sha256sum.txt
sha256sum "$BINARY_DEST_PATH"_amd64.AppImage> "$BINARY_DEST_PATH"_amd64.AppImage.sha256sum.txt
sha256sum "$BINARY_DEST_PATH"_amd64.deb> "$BINARY_DEST_PATH"_amd64.deb.sha256sum.txt

# This might catch regressions in #3384, depending how CI runners
# handle exit codes
git diff --exit-code
