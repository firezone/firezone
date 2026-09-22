#!/usr/bin/env bash
#MISE description="Fail if a fuzz target does not execute an input the same way twice"
#MISE depends=["install-toolchain", "unpack-corpus {{usage.target}}"]
#MISE raw=true
#USAGE arg "<target>"
set -euo pipefail
cd "$(dirname "$0")/.."

target="${usage_target:?}"

# libFuzzer keeps an input when it produces a feature it has not seen, so a
# target that executes the same bytes differently twice keeps growing its corpus
# with inputs that cover nothing new. The two runs below are the two ways that
# happens: state carried between executions, and state seeded per process.
copies=5
# Listed in full rather than piped into `head`, which would stop reading and
# leave `sort` with a `SIGPIPE` that `pipefail` reports as a failure.
inputs="$(find "corpus/$target" -maxdepth 1 -type f | sort)"
input="${inputs%%$'\n'*}"

if [ -z "$input" ]; then
    echo "error: the $target corpus is empty" >&2
    exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/repeated" "$work/single"
for i in $(seq "$copies"); do
    cp "$input" "$work/repeated/copy$i"
done
cp "$input" "$work/single/copy"

# `-runs=0` executes the directory and stops. Without it the target fuzzes and
# writes new units into it.
replay() {
    # Into a file rather than a pipe: a reader that stops at the line it wants
    # sends the run a `SIGPIPE` before it has finished writing.
    cargo fuzz run --sanitizer none --target x86_64-unknown-linux-gnu --fuzz-dir . --target-dir ../../target \
        "$target" "$1" -- -runs=0 -seed=1 -shuffle=0 >"$work/log" 2>&1

    grep -m1 INITED "$work/log"
}

field() {
    sed -E "s/.*\b$1: ([0-9]+).*/\1/" <<<"$2"
}

repeated="$(replay "$work/repeated")"
kept="$(field corp "$repeated")"

first="$(replay "$work/single")"
second="$(replay "$work/single")"

status=0

# The second execution is allowed to differ from the first: initialization that
# happens once, and the first reuse of a pooled allocation, are both coverage the
# first execution cannot show. From the third on, the copies are indistinguishable
# unless an execution left state behind for the next one.
if [ "$kept" -gt 2 ]; then
    echo "error: $target kept $kept of $copies identical inputs, so an execution left state behind for the next one" >&2
    echo "  $repeated" >&2
    status=1
fi

# Same input, two processes: anything seeded from the environment shows up here.
if [ "$(field cov "$first")" != "$(field cov "$second")" ] || [ "$(field ft "$first")" != "$(field ft "$second")" ]; then
    echo "error: $target covered one input differently in two processes" >&2
    echo "  $first" >&2
    echo "  $second" >&2
    status=1
fi

if [ "$status" -eq 0 ]; then
    echo "$target executes an input the same way twice."
fi

exit "$status"
