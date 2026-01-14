#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}/.."

echo "Formatting Swift code..."
git ls-files '*.swift' | xargs swift format format --in-place --parallel
