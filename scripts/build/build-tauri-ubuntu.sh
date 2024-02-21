#!/usr/bin/env bash

set -euo pipefail

# Used for release artifact
# In release mode the name comes from tauri.conf.json
cp "../target/release/Firezone.exe" "$BINARY_DEST_PATH-x64"
# TODO: Debug symbols for Linux

sha256sum "$BINARY_DEST_PATH-x64"> "$BINARY_DEST_PATH-x64.sha256sum.txt"

# This might catch regressions in #3384, depending how CI runners
# handle exit codes
git diff --exit-code
