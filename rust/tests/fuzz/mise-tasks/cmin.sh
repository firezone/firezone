#!/usr/bin/env bash
#MISE description="Minimize a fuzz corpus by AFL++ edge coverage"
#MISE depends=["install-afl"]
#MISE raw=true
#USAGE arg "<target>"
set -euo pipefail
cd "$(dirname "$0")/.."
target="${usage_target:?}"
# shellcheck source=../helpers.sh
source ./helpers.sh
build_afl
collect_findings all
shopt -s nullglob
inputs=("corpus/$target"/*)
if [ "${#inputs[@]}" -eq 0 ]; then
    echo "Corpus is missing or empty; run unpack-corpus $target first" >&2
    exit 1
fi

temporary="$(mktemp -d "corpus/.$target.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
# This floor avoids empty maps from the bundled afl-cmin's automatic size
# detection on small targets; round larger maps to AFL's 64-byte alignment.
map_size="$(AFL_DUMP_MAP_SIZE=1 "$afl_binary" "$target")" || true
[[ "$map_size" =~ ^[0-9]+$ ]] || {
    echo "Could not determine AFL++ coverage map size" >&2
    exit 1
}
map_size="$(((map_size + 63) / 64 * 64))"
[ "$map_size" -ge 65536 ] || map_size=65536
AFL_MAP_SIZE="$map_size" AFL_FUZZER_LOOPCOUNT=1 cargo afl cmin -e -i "corpus/$target" \
    -o "$temporary/minimized" -t 10000 -m none -- "$afl_binary" "$target"
shopt -s nullglob
minimized=("$temporary/minimized"/*)
if [ "${#minimized[@]}" -eq 0 ]; then
    echo "AFL++ produced an empty corpus; keeping the original inputs" >&2
    exit 1
fi
# Keep the old corpus intact until minimization succeeds.
mv "corpus/$target" "$temporary/original"
if ! mv "$temporary/minimized" "corpus/$target"; then
    mv "$temporary/original" "corpus/$target"
    exit 1
fi
