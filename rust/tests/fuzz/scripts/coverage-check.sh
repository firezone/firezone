#!/usr/bin/env bash

set -euo pipefail

crate="${1:?usage: coverage-check.sh <crate>}"
expected_file="expected-coverage/$crate.json"
measured="$(./scripts/coverage-summary.sh "$crate")"
expected="$(<"$expected_file")"
measured_uncovered="$(jq '.total - .covered' <<<"$measured")"
expected_uncovered="$(jq '.total - .covered' <<<"$expected")"
measured_percent="$(jq '100 * .covered / .total' <<<"$measured")"
expected_percent="$(jq '100 * .covered / .total' <<<"$expected")"

printf 'measured: %s (%.2f%% covered, %d uncovered)\n' \
    "$(jq -c . <<<"$measured")" "$measured_percent" "$measured_uncovered"
printf 'expected: %s (%.2f%% covered, %d uncovered)\n' \
    "$(jq -c . <<<"$expected")" "$expected_percent" "$expected_uncovered"

if (( measured_uncovered <= expected_uncovered )); then
    exit 0
fi

echo "error: $crate has $measured_uncovered uncovered regions; $expected_file allows $expected_uncovered" >&2
exit 1
