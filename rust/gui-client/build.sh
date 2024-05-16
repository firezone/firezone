#!/usr/bin/env bash

set -euo pipefail

# Dir where all the bundles are built
BUNDLES_DIR=../target/release/bundle/deb

# Copy frontend dependencies
cp node_modules/flowbite/dist/flowbite.min.js src/

# Compile TypeScript
pnpm tsc

# Compile CSS
pnpm tailwindcss -i src/input.css -o src/output.css

# Get rid of any existing debs, since we need to discover the path later
rm -rf "$BUNDLES_DIR"

# Compile Rust and bundle
pnpm tauri build

# Delete the deb that Tauri built. We're going to modify and rebuild it.
rm ../target/release/bundle/deb/*.deb
