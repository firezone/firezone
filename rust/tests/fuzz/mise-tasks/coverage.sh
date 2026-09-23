#!/usr/bin/env bash
#MISE description="Replay corpus batches in persistent processes and produce its LLVM coverage profile"
#MISE depends=["install-toolchain"]
#MISE raw=true
#USAGE arg "<target>"
set -euo pipefail
cd "$(dirname "$0")/.."
target="${usage_target:?}"
# shellcheck source=rust/tests/fuzz/helpers.sh
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
    cargo build --locked --release -p fuzz --bin "$target" \
    --target x86_64-unknown-linux-gnu --target-dir "$fuzz_target_dir/fuzz-coverage"
mkdir -p "coverage/$target"
temporary="$(mktemp -d "coverage/$target/.profiles.XXXXXX")"
pids=()
# shellcheck disable=SC2317
cleanup() {
    trap - EXIT INT TERM HUP
    for pid in "${pids[@]}"; do kill -TERM "$pid" 2>/dev/null || true; done
    for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
    rm -rf "$temporary"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
for ((worker = 0; worker < workers; worker++)); do
    mkdir "$temporary/worker-$worker"
done
for index in "${!inputs[@]}"; do
    input="${inputs[$index]}"
    ln "$input" "$temporary/worker-$((index % workers))/${input##*/}"
done
for ((worker = 0; worker < workers; worker++)); do
    LLVM_PROFILE_FILE="$temporary/%p-%m.profraw" "$coverage_binary" \
        --replay "$temporary/worker-$worker" >"$temporary/worker-$worker.log" 2>&1 &
    pids+=("$!")
done
status=0
for pid in "${pids[@]}"; do wait "$pid" || status=$?; done
cat "$temporary"/worker-*.log
[ "$status" -eq 0 ] || exit "$status"
"$(rustc --print sysroot)/lib/rustlib/x86_64-unknown-linux-gnu/bin/llvm-profdata" \
    merge -sparse "$temporary"/*.profraw -o "$temporary/coverage.profdata"
mv "$temporary/coverage.profdata" "coverage/$target/coverage.profdata"
