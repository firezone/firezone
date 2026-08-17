#!/usr/bin/env bash
#MISE description="Run a fuzz target with its target-specific defaults; extra args are passed to libFuzzer"
#MISE depends=["install-toolchain", "unpack-corpus {{usage.target}}"]
#MISE raw=true
#USAGE arg "<target>"
#USAGE arg "[libfuzzer_args]…" var=#true
set -euo pipefail
cd "$(dirname "$0")/.."

target="${usage_target:?}"

if [ -n "${usage_libfuzzer_args:-}" ]; then
    # `usage` joins variadic arguments as a shell-escaped string.
    eval "set -- $usage_libfuzzer_args"
else
    set -- -max_total_time=60
fi

if [ "$target" = "tunnel-proto" ]; then
    set -- -max_len=8192 -len_control=0 "$@"
fi

./interruptible.sh cargo fuzz run --sanitizer none --target x86_64-unknown-linux-gnu --fuzz-dir . --target-dir ../../target "$target" -- "$@"
