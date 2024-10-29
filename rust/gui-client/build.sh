#!/usr/bin/env bash

set -euo pipefail

# Dir where all the bundles are built
BUNDLES_DIR=../target/release/bundle/deb

# Copy frontend dependencies
cp node_modules/flowbite/dist/flowbite.min.js src/

# Compile CSS
pnpm tailwindcss -i src/input.css -o src/output.css

# Bundle all web assets
pnpm vite build

# Get rid of any existing debs, since we need to discover the path later
rm -rf "$BUNDLES_DIR"

# Compile Rust and bundle
pnpm tauri build

# Delete the deb that Tauri built. We're going to modify and rebuild it.
rm "$BUNDLES_DIR"/*.deb

# There should be only one directory in `bundle/deb`, we need to modify
# files inside that dir
INTERMEDIATE_DIR=$(ls -d "$BUNDLES_DIR"/*/)

# Add the scripts
cp src-tauri/deb_files/postinst src-tauri/deb_files/prerm "$INTERMEDIATE_DIR/control/"

pushd "$INTERMEDIATE_DIR"

# Rebuild the control tarball
tar -C "control" -czf "control.tar.gz" control md5sums postinst prerm

# Rebuild the deb package, and give it a predictable name that
# `tauri-rename-ubuntu.sh` can fix
ar rcs "../firezone-client-gui.deb" debian-binary control.tar.gz data.tar.gz
popd
