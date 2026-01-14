#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}/.."

echo "Auto-fixing SwiftLint violations..."
swiftlint --fix --config .swiftlint.yml

echo "Running SwiftLint..."
swiftlint lint --config .swiftlint.yml
