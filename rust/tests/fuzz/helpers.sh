#!/usr/bin/env bash
# Variables initialized here are consumed by scripts sourcing this file.
# shellcheck disable=SC2034
# Shared paths for the discovery and replay builds.
fuzz_target_dir="${FUZZ_TARGET_DIR:-$PWD/../../target}"
afl_binary="$fuzz_target_dir/afl/x86_64-unknown-linux-gnu/release/fuzz"
replay_binary="$fuzz_target_dir/fuzz-replay/x86_64-unknown-linux-gnu/release/fuzz"

build_afl() {
    # Override cargo-afl's native CPU so cached crates work across CI runners.
    RUSTFLAGS="${RUSTFLAGS:-} -C target-cpu=x86-64" cargo afl build --locked --release -p fuzz --bin fuzz \
        --target x86_64-unknown-linux-gnu --target-dir "$fuzz_target_dir/afl"
}

build_replay() {
    RUSTFLAGS="${RUSTFLAGS:-} --cfg no_fuzzing" cargo build --locked --release -p fuzz --bin fuzz \
        --target x86_64-unknown-linux-gnu --target-dir "$fuzz_target_dir/fuzz-replay"
}

collect_findings() {
    local input name kind
    mkdir -p "corpus/${target:?}" "candidates/$target" "artifacts/$target"
    shopt -s nullglob
    if [ "${1:-all}" = all ]; then
        for input in "afl-output/$target"/*/queue/id:*; do
            name="$(sha256sum "$input")"
            name="${name%% *}"
            [ -e "corpus/$target/$name" ] || [ -e "candidates/$target/$name" ] ||
                cp "$input" "candidates/$target/$name"
        done
    fi
    for kind in crashes hangs; do
        for input in "afl-output/$target"/*/"$kind"/id:*; do
            name="$(sha256sum "$input")"
            name="${name%% *}"
            [ -e "artifacts/$target/$kind-$name" ] || cp "$input" "artifacts/$target/$kind-$name"
        done
    done
}
