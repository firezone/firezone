#!/usr/bin/env bash

# Pushes iOS and macOS builds to App Store Connect

set -euo pipefail

source "./scripts/build/lib.sh"

# xcrun altool requires private keys to be files in a specific naming format
private_key_dir="$(mktemp -d)/private_keys"
private_key_file="AuthKey_$API_KEY_ID.p8"

mkdir -p "$private_key_dir"
base64_decode "$API_KEY" "$private_key_dir/$private_key_file"

cur_dir=$(pwd)
cd "$private_key_dir"

# Submit app to App Store Connect
xcrun altool \
    --upload-app \
    -f "$ARTIFACT_PATH" \
    -t iOS \
    --apiKey "$API_KEY_ID" \
    --apiIssuer "$ISSUER_ID"

# Clean up private key
rm "$PRIVATE_KEY_PATH"

cd "$cur_dir"
