#!/bin/sh

# The Windows client obviously doesn't build for *nix, but this
# script is helpful for doing UI work on those platforms for the
# Windows client.
set -e

# Copy frontend dependencies
cp node_modules/flowbite/dist/flowbite.min.js src/

# Compile TypeScript
tsc

# Compile CSS
tailwindcss -i src/input.css -o src/output.css

# Compile Rust and bundle
tauri build
