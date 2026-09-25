#!/usr/bin/env bash
#MISE description="Check that AFL++ observes identical coverage when replaying identical inputs"
#MISE depends=["unpack-corpus {{usage.target}}"]
#MISE raw=true
#USAGE arg "<target>"
set -euo pipefail
cd "$(dirname "$0")/.."
target="${usage_target:?}"
# shellcheck source=../helpers.sh
source ./helpers.sh
# Standalone AFL++ tools do not detect the target's deferred-forkserver marker.
export LC_ALL=C AFL_FUZZER_LOOPCOUNT=1 __AFL_DEFER_FORKSRV=1
unset AFL_CMIN_ALLOW_ANY AFL_CMIN_CRASHES_ONLY
ulimit -c 0
shopt -s nullglob
inputs=("corpus/$target"/*)
if [ "${#inputs[@]}" -eq 0 ]; then
    echo "The $target corpus is empty" >&2
    exit 1
fi
build_afl

temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
mkdir "$temporary/inputs"
for index in "${!inputs[@]}"; do
    if [ ! -f "${inputs[index]}" ] || [ ! -s "${inputs[index]}" ]; then
        echo "AFL++ directory replay requires a nonempty file: ${inputs[index]}" >&2
        exit 1
    fi
    cp "${inputs[index]}" "$temporary/inputs/$index-0"
done
samples=8
[ "${#inputs[@]}" -ge "$samples" ] || samples="${#inputs[@]}"
for ((sample = 0; sample < samples; sample++)); do
    index=$((sample * ${#inputs[@]} / samples))
    for copy in 1 2 3 4; do
        cp "${inputs[index]}" "$temporary/inputs/$index-$copy"
    done
done

for run in 1 2; do
    # -Z leaves an empty map for any crash or timeout, including an earlier
    # failure that showmap's final-input exit status would otherwise miss.
    AFL_QUIET=1 cargo afl showmap -Z -i "$temporary/inputs" \
        -o "$temporary/maps-$run" -t 10000 -m none -- "$afl_binary" "$target"
    for input in "$temporary/inputs"/*; do
        name="${input##*/}"
        index="${name%-*}"
        map="$temporary/maps-$run/$name"
        if [ ! -s "$map" ]; then
            echo "Missing coverage for ${inputs[index]}: input crashed, timed out, or was skipped" >&2
            exit 1
        fi
        # Compare AFL's classified hit counts as well as the actual edge IDs.
        if ! cmp -s "$map" "$temporary/maps-$run/$index-0" ||
            { [ "$run" -eq 2 ] && ! cmp -s "$map" "$temporary/maps-1/$name"; }; then
            echo "$target produced different AFL++ coverage for ${inputs[index]} (run $run, copy ${name##*-})" >&2
            exit 1
        fi
    done
done
echo "$target: ${#inputs[@]} inputs match across two forkservers; $samples inputs also match across five children each."
