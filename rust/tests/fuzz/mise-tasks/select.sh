#!/usr/bin/env bash
#MISE description="Add the candidate inputs that reach an edge the committed corpus does not"
#MISE raw=true
#USAGE arg "<target>"
set -euo pipefail
cd "$(dirname "$0")/.."
target="${usage_target:?}"
# shellcheck source=../helpers.sh
source ./helpers.sh
export LC_ALL=C AFL_QUIET=1 AFL_FUZZER_LOOPCOUNT=1
ulimit -c 0
shopt -s nullglob
candidates=("candidates/$target"/*)
if [ "${#candidates[@]}" -eq 0 ]; then
    echo "$target: no candidates."
    exit 0
fi
build_afl

temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
showmap() {
    # -Z leaves an empty map for a crash or timeout instead of failing.
    cargo afl showmap -Z -e -i "$1" -o "$2" -t 10000 -m none -- "$afl_binary" "$target"
}
mkdir -p "corpus/$target"
committed=("corpus/$target"/*)
: >"$temporary/edges"
if [ "${#committed[@]}" -gt 0 ]; then
    showmap "corpus/$target" "$temporary/corpus"
    sort -u "$temporary/corpus"/* >"$temporary/edges"
fi
showmap "candidates/$target" "$temporary/candidates"

# Smallest first, so the smallest of several candidates claims a shared edge.
kept=0
while IFS= read -r candidate; do
    name="${candidate##*/}"
    sort -u "$temporary/candidates/$name" >"$temporary/candidate"
    if comm -23 "$temporary/candidate" "$temporary/edges" | grep -q .; then
        sort -u -o "$temporary/edges" "$temporary/edges" "$temporary/candidate"
        cp "$candidate" "corpus/$target/$name"
        chmod 0644 "corpus/$target/$name"
        kept=$((kept + 1))
    fi
done < <(stat -c '%s %n' "${candidates[@]}" | sort -n | cut -d ' ' -f 2-)
rm -rf "candidates/$target"
echo "$target: kept $kept of ${#candidates[@]} candidates."
