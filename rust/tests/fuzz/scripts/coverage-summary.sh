#!/usr/bin/env bash

set -euo pipefail

crate="${1:?usage: coverage-summary.sh <crate>}"
profile="coverage/$crate/coverage.profdata"
binary="../../target/x86_64-unknown-linux-gnu/release/$crate"
llvm_cov="$(rustc --print sysroot)/lib/rustlib/x86_64-unknown-linux-gnu/bin/llvm-cov"
manifest="$(
    cargo metadata --format-version=1 --no-deps |
        jq -er --arg crate "$crate" '.packages[] | select(.name == $crate) | .manifest_path'
)"
crate_dir="${manifest%/Cargo.toml}/"

"$llvm_cov" export -instr-profile="$profile" "$binary" |
    jq -e --arg crate_dir "$crate_dir" '
        [.data[].files[]
            | select(.filename | startswith($crate_dir))
            | .summary.regions
        ]
        | if length == 0 then
            error("coverage profile contains no files for " + $crate_dir)
        else
            {
                covered: (map(.covered) | add),
                total: (map(.count) | add)
            }
        end
    '
