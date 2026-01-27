#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}/.."

echo "Checking Kotlin code style..."
mise exec -- ./gradlew spotlessCheck

echo "Running Android Lint..."
mise exec -- ./gradlew lint
