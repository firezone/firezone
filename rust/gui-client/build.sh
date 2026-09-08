#!/usr/bin/env bash

set -euo pipefail

# Bundle all web assets
pnpm vite build

# The `firezone` CLI is its own workspace member, so `tauri build` never
# compiles it. The deb and rpm `files` maps pick it up from `target/release`.
cargo build --release -p firezone-cli

# Compile Rust and bundle
pnpm tauri build
