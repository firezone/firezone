#!/usr/bin/env bash
set -euo pipefail

echo "Installing required Rust targets..."
rustup target add aarch64-apple-darwin x86_64-apple-darwin
rustup target add aarch64-apple-ios x86_64-apple-ios
echo "Setup complete!"
