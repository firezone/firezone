#!/usr/bin/env bash
#MISE description="Move a fuzz target's failing inputs into its corpus so they get committed"
#MISE raw=true
#USAGE arg "<target>"
set -euo pipefail
cd "$(dirname "$0")/.."

target="${usage_target:?}"
corpus="corpus/$target"

# The corpus is the only thing this directory commits, and pull-request CI
# replays all of it, so an input parked here reproduces the crash on every run
# until the bug behind it is fixed. It keeps its `crash-` name to say why it is
# there; the next `cmin` after the fix re-emits it under its content hash like
# any other input.
#
# One easily reached bug yields a distinct input on every hit and the run no
# longer stops at the first, so cap what a run adds rather than committing
# hundreds of variations on the same backtrace.
limit=10
kept=0
dropped=0

# `slow-unit-*` is deliberately absent: libFuzzer writes those while carrying
# on, so adding them would accumulate inputs that nothing is wrong with.
for artifact in \
    "artifacts/$target"/crash-* \
    "artifacts/$target"/timeout-* \
    "artifacts/$target"/oom-* \
    "artifacts/$target"/leak-*; do
    [ -e "$artifact" ] || continue

    if [ "$kept" -ge "$limit" ]; then
        dropped=$((dropped + 1))
        continue
    fi

    name="${artifact##*/}"

    mkdir -p "$corpus"
    mv -f "$artifact" "$corpus/$name"
    chmod 0644 "$corpus/$name"
    kept=$((kept + 1))

    echo "Added $name to $corpus"
done

if [ "$kept" -eq 0 ]; then
    echo "No failing input to add."
    exit 0
fi

echo "Added $kept failing input(s) to $corpus."

if [ "$dropped" -gt 0 ]; then
    echo "Dropped $dropped more: a run adds at most $limit."
fi
