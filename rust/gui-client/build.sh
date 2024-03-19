#!/usr/bin/env bash

set -euo pipefail

# Copy frontend dependencies
cp node_modules/flowbite/dist/flowbite.min.js src/

# Compile TypeScript
pnpm tsc

# Compile CSS
pnpm tailwindcss -i src/input.css -o src/output.css

# Compile Rust and bundle
pnpm tauri build
