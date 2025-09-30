#!/usr/bin/env bash

# Unit tests for lib.sh helper functions

set -euo pipefail

# Source the library functions (but disable set -x for cleaner test output)
set +x
source "$(dirname "$0")/lib.sh"
set +x  # lib.sh re-enables it, so disable again

TEST_PASSED=0
TEST_FAILED=0

function test_expect_error_with_failing_command() {
    echo "=== Testing expect_error with failing command ==="
    if expect_error false; then
        echo "✓ Test passed: expect_error correctly handled failing command"
        TEST_PASSED=$((TEST_PASSED + 1))
    else
        echo "✗ Test failed: expect_error should succeed when command fails"
        TEST_FAILED=$((TEST_FAILED + 1))
    fi
}

function test_expect_error_with_succeeding_command() {
    echo "=== Testing expect_error with succeeding command ==="
    if expect_error true; then
        echo "✗ Test failed: expect_error should fail when command succeeds"
        TEST_FAILED=$((TEST_FAILED + 1))
    else
        echo "✓ Test passed: expect_error correctly failed when command succeeded"
        TEST_PASSED=$((TEST_PASSED + 1))
    fi
}

function test_expect_error_code_matching() {
    echo "=== Testing expect_error_code with matching exit code ==="
    if expect_error_code 42 bash -c "exit 42"; then
        echo "✓ Test passed: expect_error_code correctly matched exit code 42"
        TEST_PASSED=$((TEST_PASSED + 1))
    else
        echo "✗ Test failed: expect_error_code should succeed when exit codes match"
        TEST_FAILED=$((TEST_FAILED + 1))
    fi
}

function test_expect_error_code_not_matching() {
    echo "=== Testing expect_error_code with non-matching exit code ==="
    if expect_error_code 42 bash -c "exit 1"; then
        echo "✗ Test failed: expect_error_code should fail when exit codes don't match"
        TEST_FAILED=$((TEST_FAILED + 1))
    else
        echo "✓ Test passed: expect_error_code correctly failed when exit codes differed"
        TEST_PASSED=$((TEST_PASSED + 1))
    fi
}

function test_expect_error_code_zero() {
    echo "=== Testing expect_error_code with exit code 0 ==="
    if expect_error_code 0 true; then
        echo "✓ Test passed: expect_error_code correctly matched exit code 0"
        TEST_PASSED=$((TEST_PASSED + 1))
    else
        echo "✗ Test failed: expect_error_code should succeed for exit code 0"
        TEST_FAILED=$((TEST_FAILED + 1))
    fi
}

# Run all tests
test_expect_error_with_failing_command
test_expect_error_with_succeeding_command
test_expect_error_code_matching
test_expect_error_code_not_matching
test_expect_error_code_zero

# Print summary
echo ""
echo "========================================"
echo "Test Summary:"
echo "  Passed: $TEST_PASSED"
echo "  Failed: $TEST_FAILED"
echo "========================================"

if [ $TEST_FAILED -eq 0 ]; then
    echo "All tests passed! ✓"
    exit 0
else
    echo "Some tests failed! ✗"
    exit 1
fi