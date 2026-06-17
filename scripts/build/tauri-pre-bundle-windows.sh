#!/usr/bin/env bash
# Driven by `tauri.windows.conf.json:beforeBundleCommand` to run after
# `cargo build` produces the release binaries but before Tauri/WiX
# assembles the MSI.
#
# Tauri's CLI splits the JSON `beforeBundleCommand` string into
# program + args via a shell-words-style tokenizer that doesn't
# reliably honour inline `bash -xc '...; ...; ...'` quoting on Windows
# (Git Bash) — `;` leaks into downstream argv. Keeping the inline
# command trivial (one program + one arg) and putting the real logic
# in a script file sidesteps that.
#
# Sequence:
#   1. Diagnostic: print cwd + contents of `target/release/` so any
#      missing-binary case is obvious in the CI log.
#   2. Sign the side EXEs that ship in the MSI bundle.
#   3. Build (and sign) the sparse MSIX that WiX picks up.
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_DIR="$WORKSPACE_ROOT/rust/target/release"

echo "tauri-pre-bundle-windows.sh: PWD=$(pwd)"
echo "tauri-pre-bundle-windows.sh: TARGET_DIR=$TARGET_DIR"
ls -la "$TARGET_DIR" 2>&1 | head -n 60 || true

powershell.exe -NoProfile -File "$SCRIPT_DIR/sign.ps1" \
    "$TARGET_DIR/firezone-client-tunnel.exe" \
    "$TARGET_DIR/register-sparse.exe"

bash "$SCRIPT_DIR/build-msix-windows.sh"
