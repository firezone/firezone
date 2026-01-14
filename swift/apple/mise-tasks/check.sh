#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}/.."

echo "Checking Swift formatting..."
git ls-files '*.swift' | xargs swift format lint --parallel --strict

echo "Running SwiftLint..."
swiftlint lint --config .swiftlint.yml --strict
