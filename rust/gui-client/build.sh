#!/usr/bin/env bash

set -euo pipefail

# Bundle all web assets
pnpm vite build

# Compile Rust and bundle
pnpm tauri build
