#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPLE_DIR="${SCRIPT_DIR}/.."

echo "Running FirezoneKit tests..."
cd "${APPLE_DIR}/FirezoneKit" && swift test
