#!/usr/bin/env bash

# Pushes iOS and macOS builds to App Store Connect

set -euo pipefail

# xcrun altool requires private keys to be files in a specific naming format
API_PRIVATE_KEYS_DIR=${API_PRIVATE_KEYS_DIR:-$RUNNER_TEMP}
PRIVATE_KEY_PATH="$API_PRIVATE_KEYS_DIR/AuthKey_$API_KEY_ID.p8"
echo -n "$API_KEY" | base64 --decode -o "$PRIVATE_KEY_PATH"

# Submit app to App Store Connect
xcrun altool \
    --upload-app \
    -f "$ARTIFACT_PATH" \
    -t iOS \
    --apiKey "$API_KEY_ID" \
    --apiIssuer "$ISSUER_ID"

# Clean up private key
rm "$PRIVATE_KEY_PATH"
