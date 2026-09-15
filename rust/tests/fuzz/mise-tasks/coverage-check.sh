#!/usr/bin/env bash
#MISE description="Fail if a fuzz target exceeds its committed uncovered-region ceiling"
#MISE raw=true
#USAGE arg "<target>"
set -euo pipefail
cd "$(dirname "$0")/.."

target="${usage_target:?}"
expected_file="expected-coverage/$target.json"
measured="$(mise run -q //rust/tests/fuzz:coverage-summary "$target")"
expected="$(<"$expected_file")"
measured_uncovered="$(jq '.total - .covered' <<<"$measured")"
expected_uncovered="$(jq '.total - .covered' <<<"$expected")"
measured_percent="$(jq '100 * .covered / .total' <<<"$measured")"
expected_percent="$(jq '100 * .covered / .total' <<<"$expected")"
failed=0

printf 'measured: %s (%.2f%% covered, %d uncovered)\n' \
    "$(jq -c . <<<"$measured")" "$measured_percent" "$measured_uncovered"
printf 'expected: %s (%.2f%% covered, %d uncovered)\n' \
    "$(jq -c . <<<"$expected")" "$expected_percent" "$expected_uncovered"

if ((measured_uncovered > expected_uncovered)); then
    echo "error: $target has $measured_uncovered uncovered regions; $expected_file allows $expected_uncovered" >&2
    failed=1
fi

if [[ "$target" == "tunnel-proto" ]]; then
    profile="coverage/$target/coverage.profdata"
    binary="../../target/x86_64-unknown-linux-gnu/release/$target"
    llvm_cov="$(rustc --print sysroot)/lib/rustlib/x86_64-unknown-linux-gnu/bin/llvm-cov"
    resource_edit_path="rust/tests/fuzz/src/resource_edit_path_coverage.rs"
    resource_edit_regions="$("$llvm_cov" export \
        --summary-only \
        --skip-functions \
        -instr-profile="$profile" \
        "$binary" | jq -e --arg suffix "$resource_edit_path" '
            [.data[].files[]
              | select(.filename | endswith($suffix))
              | .summary.regions
            ]
            | if length == 1 then
                .[0]
              else
                error("expected exactly one resource-edit coverage file")
              end
        ')"
    resource_edit_covered="$(jq '.covered' <<<"$resource_edit_regions")"
    resource_edit_total="$(jq '.count' <<<"$resource_edit_regions")"

    printf 'resource edit paths: %d/%d regions covered\n' \
        "$resource_edit_covered" "$resource_edit_total"

    if ((resource_edit_covered != resource_edit_total)); then
        echo "error: the corpus does not complete every resource-edit path" >&2
        failed=1
    fi
fi

exit "$failed"
