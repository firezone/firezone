#!/usr/bin/env bash
#MISE description="Print region coverage of our own crates for a fuzz target"
#MISE raw=true
#USAGE arg "<target>"
set -euo pipefail
cd "$(dirname "$0")/.."

target="${usage_target:?}"
profile="coverage/$target/coverage.profdata"
binary="../../target/x86_64-unknown-linux-gnu/release/$target"
llvm_cov="$(rustc --print sysroot)/lib/rustlib/x86_64-unknown-linux-gnu/bin/llvm-cov"

if [ ! -f "$profile" ]; then
    echo "error: coverage profile is missing; run mise run //rust/tests/fuzz:coverage $target first" >&2
    exit 1
fi

# A fuzz build instruments the dependencies too, so the profile already covers
# every workspace crate the target links. Keeping all of them means the baseline
# tracks the code we own rather than the one crate sharing the target's name.
crates="$(mise run -q //rust:workspace-crates)"

"$llvm_cov" export -instr-profile="$profile" "$binary" |
    jq -e --argjson crates "$crates" '
    [.data[].files[]
      | .filename as $file
      | select($crates | any(.dir as $dir | $file | startswith($dir)))
      | .summary.regions
    ]
    | if length == 0 then
        error("coverage profile contains no files from this workspace")
      else
        {
          covered: (map(.covered) | add),
          total: (map(.count) | add)
        }
      end
  '
