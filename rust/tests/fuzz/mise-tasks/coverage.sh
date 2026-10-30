#!/usr/bin/env bash
#MISE description="Replay a corpus with LLVM coverage and export lcov for Coveralls"
#MISE raw=true
#USAGE arg "<target>"
set -euo pipefail
cd "$(dirname "$0")/.."
target="${usage_target:?}"
# shellcheck source=../helpers.sh
source ./helpers.sh

binary="$fuzz_target_dir/fuzz-coverage/x86_64-unknown-linux-gnu/release/fuzz"
llvm_bin="$(rustc --print sysroot)/lib/rustlib/x86_64-unknown-linux-gnu/bin"
RUSTFLAGS="${RUSTFLAGS:-} --cfg no_fuzzing -C instrument-coverage -C debuginfo=line-tables-only" \
    cargo build --locked --release -p fuzz --bin fuzz \
    --target x86_64-unknown-linux-gnu --target-dir "$fuzz_target_dir/fuzz-coverage"

mkdir -p "coverage/$target"
temporary="$(mktemp -d "coverage/$target/.profiles.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
LLVM_PROFILE_FILE="$temporary/%p-%m.profraw" "$binary" "$target" --replay "corpus/$target"
"$llvm_bin/llvm-profdata" merge -sparse "$temporary"/*.profraw -o "$temporary/coverage.profdata"

packages="$(cargo tree --locked -p "$target" --edges normal --prefix none --format '{p}' \
    --target x86_64-unknown-linux-gnu | cut -d ' ' -f 1 | sort -u | jq -Rsc 'split("\n")[:-1]')"
crates="$(mise run -q //rust:workspace-crates)"
directories="$(jq -r --argjson packages "$packages" \
    '.[] | select(.name as $name | $packages | index($name)) | .dir' <<<"$crates")"
[ -n "$directories" ]
sources=()
while IFS= read -r directory; do
    mapfile -t -O "${#sources[@]}" sources < <(find "$directory" -type f -name '*.rs')
done <<<"$directories"
sources+=("$PWD/src/main.rs" "$PWD/src/clock.rs" "$PWD/src/targets/${target//-/_}.rs")
if [ "$target" = tunnel-proto ]; then
    mapfile -t -O "${#sources[@]}" sources < <(find "$PWD/src" -type f -name '*.rs' \
        ! -path "$PWD/src/targets/*" ! -name main.rs ! -name clock.rs)
fi
"$llvm_bin/llvm-cov" export -format=lcov -instr-profile="$temporary/coverage.profdata" \
    "$binary" "${sources[@]}" >"coverage/$target/lcov.info"
