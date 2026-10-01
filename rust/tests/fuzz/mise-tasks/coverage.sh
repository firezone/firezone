#!/usr/bin/env bash
#MISE description="Replay corpus batches in persistent processes and produce its LLVM coverage profile"
#MISE raw=true
#USAGE arg "<target>"
set -euo pipefail
cd "$(dirname "$0")/.."
target="${usage_target:?}"
# shellcheck source=../helpers.sh
source ./helpers.sh

shopt -s nullglob
inputs=("corpus/$target"/*)
if [ "${#inputs[@]}" -eq 0 ]; then
    echo "Corpus is missing or empty; run unpack-corpus $target first" >&2
    exit 1
fi
# Each worker processes a sizeable batch without forking once per input.
workers="$((${#inputs[@]} / 100))"
[ "$workers" -gt 0 ] || workers=1
workers="${FUZZ_REPLAY_WORKERS-$workers}"
[[ "$workers" =~ ^[1-9][0-9]*$ ]] || {
    echo "FUZZ_REPLAY_WORKERS must be a positive integer" >&2
    exit 1
}
[ "$workers" -le "$(nproc)" ] || workers="$(nproc)"
[ "$workers" -le "${#inputs[@]}" ] || workers="${#inputs[@]}"

RUSTFLAGS="${RUSTFLAGS:-} --cfg no_fuzzing -C instrument-coverage -C debuginfo=line-tables-only" \
    cargo build --locked --release -p fuzz --bin fuzz \
    --target x86_64-unknown-linux-gnu --target-dir "$fuzz_target_dir/fuzz-coverage"
mkdir -p "coverage/$target"
temporary="$(mktemp -d "coverage/$target/.profiles.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
batch_size="$(((${#inputs[@]} + workers - 1) / workers))"
printf '%s\0' "${inputs[@]}" |
    LLVM_PROFILE_FILE="$temporary/%p-%m.profraw" \
        xargs -0 -P "$workers" -n "$batch_size" "$coverage_binary" "$target" --replay
"$(rustc --print sysroot)/lib/rustlib/x86_64-unknown-linux-gnu/bin/llvm-profdata" \
    merge -sparse "$temporary"/*.profraw -o "$temporary/coverage.profdata"
mv "$temporary/coverage.profdata" "coverage/$target/coverage.profdata"
