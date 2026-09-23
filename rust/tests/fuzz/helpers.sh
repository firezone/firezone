#!/usr/bin/env bash
# Variables initialized here are consumed by scripts sourcing this file.
# shellcheck disable=SC2034
# Shared paths for the discovery, replay, and source-coverage builds.
fuzz_target_dir="${FUZZ_TARGET_DIR:-$PWD/../../target}"
afl_binary="$fuzz_target_dir/afl/x86_64-unknown-linux-gnu/release/fuzz"
replay_binary="$fuzz_target_dir/fuzz-replay/x86_64-unknown-linux-gnu/release/fuzz"
coverage_binary="$fuzz_target_dir/fuzz-coverage/x86_64-unknown-linux-gnu/release/fuzz"

build_afl() {
    cargo afl build --locked --release -p fuzz --bin fuzz \
        --target x86_64-unknown-linux-gnu --target-dir "$fuzz_target_dir/afl"
}

build_replay() {
    RUSTFLAGS="${RUSTFLAGS:-} --cfg no_fuzzing" cargo build --locked --release -p fuzz --bin fuzz \
        --target x86_64-unknown-linux-gnu --target-dir "$fuzz_target_dir/fuzz-replay"
}

# Scope a target's coverage to its workspace dependencies and test harness.
coverage_sources() {
    local packages crates directories directory
    packages="$(cargo tree --locked -p "${target:?}" --edges normal --prefix none --format '{p}' \
        --target x86_64-unknown-linux-gnu | cut -d ' ' -f 1 | sort -u | jq -Rsc 'split("\n")[:-1]')"
    crates="$(mise run -q //rust:workspace-crates)"
    directories="$(jq -r --argjson packages "$packages" \
        '.[] | select(.name as $name | $packages | index($name)) | .dir' <<<"$crates")"
    [ -n "$directories" ] || return 1
    while IFS= read -r directory; do
        find "$directory" -type f -name '*.rs'
    done <<<"$directories"
    printf '%s\n' "$PWD/src/main.rs" "$PWD/src/clock.rs" "$PWD/src/seeded_rng.rs" "$PWD/src/targets/${target//-/_}.rs"
    if [ "$target" = tunnel-proto ]; then
        find "$PWD/src" -type f -name '*.rs' ! -path "$PWD/src/targets/*" ! -name main.rs ! -name clock.rs ! -name seeded_rng.rs
    fi
}

collect_findings() {
    local input name kind
    mkdir -p "corpus/${target:?}" "artifacts/$target"
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
