#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPLE_DIR="${SCRIPT_DIR}/.."
FIREZONE_KIT_DIR="${APPLE_DIR}/FirezoneKit"

echo "Running FirezoneKit tests with coverage..."
cd "${FIREZONE_KIT_DIR}"
swift test --enable-code-coverage

echo "Converting coverage to lcov format..."
BIN_PATH=$(swift build --show-bin-path)
PROFDATA="${BIN_PATH}/codecov/default.profdata"
TEST_BINARY="${BIN_PATH}/FirezoneKitPackageTests.xctest/Contents/MacOS/FirezoneKitPackageTests"
COVERAGE_FILE="${FIREZONE_KIT_DIR}/coverage.lcov"

xcrun llvm-cov export \
    "${TEST_BINARY}" \
    -instr-profile="${PROFDATA}" \
    -format=lcov \
    -ignore-filename-regex='\.build|Tests' \
    > "${COVERAGE_FILE}"

echo "Coverage report generated: ${COVERAGE_FILE}"

# Calculate coverage percentage from lcov data
# LF = lines found (total), LH = lines hit (covered)
LINES_FOUND=$(grep "^LF:" "${COVERAGE_FILE}" | cut -d: -f2 | awk '{sum += $1} END {print sum}')
LINES_HIT=$(grep "^LH:" "${COVERAGE_FILE}" | cut -d: -f2 | awk '{sum += $1} END {print sum}')

if [ "${LINES_FOUND}" -gt 0 ]; then
    PERCENTAGE=$(awk "BEGIN {printf \"%.1f\", (${LINES_HIT} / ${LINES_FOUND}) * 100}")
    echo ""
    echo "Coverage: ${PERCENTAGE}% (${LINES_HIT}/${LINES_FOUND} lines)"
else
    echo "No coverage data found"
fi
