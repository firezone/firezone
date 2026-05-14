#!/usr/bin/env bash
# `tauri.windows.conf.json:beforeBundleCommand` runs Tauri's command
# through an arg-splitter that doesn't reliably honor inline `bash -xc
# '...; ...; ...'` quoting on Windows (Git Bash) — `;` leaks into
# downstream argv. We work around that by keeping the inline command
# trivial (one program + one arg) and putting the actual logic here.
#
# Sequence:
#   1. Diagnostic: print cwd + contents of `target/release/` so any
#      missing-binary case is obvious in the CI log.
#   2. Sign the three EXEs that ship in the MSI bundle.
#   3. Build (and sign) the sparse MSIX that WiX picks up.
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_TAURI_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_ROOT="$(cd "$SRC_TAURI_DIR/../../.." && pwd)"
TARGET_DIR="$WORKSPACE_ROOT/rust/target/release"

echo "pre-bundle.sh: PWD=$(pwd)"
echo "pre-bundle.sh: TARGET_DIR=$TARGET_DIR"
ls -la "$TARGET_DIR" 2>&1 | head -n 60 || true

"$WORKSPACE_ROOT/scripts/build/sign.sh" \
    "$TARGET_DIR/Firezone.exe" \
    "$TARGET_DIR/firezone-client-tunnel.exe" \
    "$TARGET_DIR/register-sparse.exe"

bash "$SCRIPT_DIR/build-msix.sh"
