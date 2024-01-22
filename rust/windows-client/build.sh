#!/bin/sh

set -e

# Copy frontend dependencies
cp node_modules/flowbite/dist/flowbite.min.js src/

# Compile TypeScript
tsc

# Compile CSS
tailwindcss -i src/input.css -o src/output.css

# Compile Rust and bundle
tauri build
