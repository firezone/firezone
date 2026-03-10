#!/usr/bin/env bash
#MISE description="CLI smoke tests — basic (no tunnel, works in CI)"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPLE_DIR="${SCRIPT_DIR}/.."
CONFIGURATION="${CONFIGURATION:-Debug}"

cd "${APPLE_DIR}"

# Locate the CLI binary via xcodebuild
xcodebuild_output=$(xcodebuild -project Firezone.xcodeproj -scheme Firezone -configuration "${CONFIGURATION}" -showBuildSettings 2>&1) || {
    echo "Error: xcodebuild failed:" >&2
    echo "$xcodebuild_output" >&2
    exit 1
}
PRODUCTS_DIR=$(echo "$xcodebuild_output" | grep ' BUILT_PRODUCTS_DIR = ' | sed 's/.*= //')
if [ -z "$PRODUCTS_DIR" ]; then
    echo "Error: Could not determine build products directory" >&2
    exit 1
fi

CLI_PATH="$PRODUCTS_DIR/Firezone.app/Contents/MacOS/firezone"
if [ ! -x "$CLI_PATH" ]; then
    echo "Error: firezone CLI not found at $CLI_PATH" >&2
    echo "Run 'mise run //swift/apple:build' first." >&2
    exit 1
fi

echo "Testing CLI at: $CLI_PATH"
echo "---"

PASS=0
FAIL=0

assert_exit_code() {
    local description="$1"
    local expected_code="$2"
    shift 2
    local actual_code=0
    "$@" > /dev/null 2>&1 || actual_code=$?
    if [ "$actual_code" -eq "$expected_code" ]; then
        echo "PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description (expected exit $expected_code, got $actual_code)"
        FAIL=$((FAIL + 1))
    fi
}

assert_output_contains() {
    local description="$1"
    local expected_pattern="$2"
    shift 2
    local output
    output=$("$@" 2>&1) || true
    if echo "$output" | grep -qi "$expected_pattern"; then
        echo "PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description (output did not contain '$expected_pattern')"
        echo "  Got: $output"
        FAIL=$((FAIL + 1))
    fi
}

# 1. --help exits 0 and shows usage
assert_exit_code "--help exits 0" 0 "$CLI_PATH" --help
assert_output_contains "--help shows USAGE" "USAGE:" "$CLI_PATH" --help

# 2. --version exits 0 and shows version string
assert_exit_code "--version exits 0" 0 "$CLI_PATH" --version
assert_output_contains "--version shows version" "[0-9]" "$CLI_PATH" --version

# 3. --check doesn't crash; exits 0 (token found) or non-zero with "No token found"
check_exit=0
check_output=$("$CLI_PATH" --check 2>&1) || check_exit=$?
if [ "$check_exit" -eq 0 ]; then
    echo "PASS: --check exits 0 (token present)"
    PASS=$((PASS + 1))
elif echo "$check_output" | grep -qi "No token found"; then
    echo "PASS: --check exits non-zero with 'No token found' (no token)"
    PASS=$((PASS + 1))
else
    echo "FAIL: --check exited $check_exit with unexpected output: $check_output"
    FAIL=$((FAIL + 1))
fi

# 4. --exit flag is accepted (combined with --check to avoid starting the tunnel)
assert_exit_code "--exit --check exits 0" 0 "$CLI_PATH" --exit --check

# 5. sign-in --help exits 0 and shows account-slug
assert_exit_code "sign-in --help exits 0" 0 "$CLI_PATH" sign-in --help
assert_output_contains "sign-in --help shows account-slug" "account-slug" "$CLI_PATH" sign-in --help

# 5. sign-out --help exits 0 and shows Sign out
assert_exit_code "sign-out --help exits 0" 0 "$CLI_PATH" sign-out --help
assert_output_contains "sign-out --help shows 'Sign out'" "Sign out" "$CLI_PATH" sign-out --help

echo "---"
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
