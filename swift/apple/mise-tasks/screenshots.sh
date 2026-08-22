#!/usr/bin/env bash
#MISE description="Render the macOS screens to PNGs in swift/apple/screenshots"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPLE_DIR="${SCRIPT_DIR}/.."

echo "Rendering screenshots..."
cd "${APPLE_DIR}/FirezoneKit" && swift test --filter Screenshots

echo "Wrote ${APPLE_DIR}/screenshots"
