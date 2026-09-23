#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154
# Shared paths for the discovery, replay, and source-coverage builds.
fuzz_target_dir="${FUZZ_TARGET_DIR:-$PWD/../../target}"
afl_binary="$fuzz_target_dir/afl/x86_64-unknown-linux-gnu/release/$target"
replay_binary="$fuzz_target_dir/fuzz-replay/x86_64-unknown-linux-gnu/release/$target"
coverage_binary="$fuzz_target_dir/fuzz-coverage/x86_64-unknown-linux-gnu/release/$target"

build_afl() {
    cargo afl build --locked --release -p fuzz --bin "$target" \
        --target x86_64-unknown-linux-gnu --target-dir "$fuzz_target_dir/afl"
}

build_replay() {
    RUSTFLAGS="${RUSTFLAGS:-} --cfg no_fuzzing" cargo build --locked --release -p fuzz --bin "$target" \
        --target x86_64-unknown-linux-gnu --target-dir "$fuzz_target_dir/fuzz-replay"
}

collect_findings() {
    local input name kind
    mkdir -p "corpus/$target" "artifacts/$target"
    shopt -s nullglob
    if [ "${1:-all}" = all ]; then
        for input in "afl-output/$target"/*/queue/id:*; do
            name="$(sha256sum "$input")"
            name="${name%% *}"
            [ -e "corpus/$target/$name" ] || cp "$input" "corpus/$target/$name"
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
