#!/usr/bin/env bash
set -euo pipefail

# For debugging
ls ../target/release ../target/debian

# Used for release artifact
# In release mode the name comes from tauri.conf.json
# Using a glob for the source, there will only be one exe and one deb anyway
cp ../target/release/firezone-gui-client "$BINARY_DEST_PATH"-amd64
cp ../target/release/firezone-gui-client.dwp "$BINARY_DEST_PATH"-amd64.dwp
cp ../target/debian/*_amd64.deb "$BINARY_DEST_PATH"_amd64.deb
# TODO: Debug symbols for Linux

function make_hash() {
    sha256sum "$1"> "$1.sha256sum.txt"
}

# I think we agreed in standup to just match platform conventions
# Firezone for Windows is "-x64" which I believe is Visual Studio's convention
# Debian calls it "amd64". Rust and Linux call it "x86_64". So whatever, it's
# amd64 here. They're all the same.
make_hash "$BINARY_DEST_PATH"-amd64
make_hash "$BINARY_DEST_PATH"-amd64.dwp
make_hash "$BINARY_DEST_PATH"_amd64.deb
