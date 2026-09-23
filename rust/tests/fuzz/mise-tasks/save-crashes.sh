#!/usr/bin/env bash
#MISE description="Copy failing inputs into a target's committed corpus"
#MISE raw=true
#USAGE arg "<target>"
set -euo pipefail
cd "$(dirname "$0")/.."
target="${usage_target:?}"
# shellcheck source=rust/tests/fuzz/helpers.sh
source ./helpers.sh
collect_findings crashes

# Cap variations of the same failure; retain all originals in artifacts.
kept=0
shopt -s nullglob
for artifact in "artifacts/$target"/crashes-* "artifacts/$target"/hangs-*; do
    [ "$kept" -lt 10 ] || break
    cp "$artifact" "corpus/$target/${artifact##*/}"
    chmod 0644 "corpus/$target/${artifact##*/}"
    kept=$((kept + 1))
done
echo "Added $kept failing input(s) to corpus/$target."
