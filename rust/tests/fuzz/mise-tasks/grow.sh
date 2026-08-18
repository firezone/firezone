#!/usr/bin/env bash
#MISE description="Fuzz a target, then minimize, re-baseline and repack its corpus, crashes included"
#MISE raw=true
#USAGE arg "<target>"
#USAGE arg "[libfuzzer_args]…" var=#true
set -euo pipefail
cd "$(dirname "$0")/.."

target="${usage_target:?}"

if [ -n "${usage_libfuzzer_args:-}" ]; then
    # `usage` joins variadic arguments as a shell-escaped string.
    eval "set -- $usage_libfuzzer_args"
else
    # CI has the machine to itself. A developer is still using theirs during the
    # half hour this takes, so leave them a quarter of the cores.
    if [ -n "${CI:-}" ]; then
        fork="$(nproc)"
    else
        fork="$(($(nproc) * 3 / 4))"
        if [ "$fork" -lt 1 ]; then
            fork=1
        fi
    fi

    # `-fork` re-merges the whole seed corpus before it discovers anything, and
    # `-max_total_time` does not bound that startup. A short budget would be
    # spent entirely inside it, so this matches what the nightly job asks for.
    set -- "-fork=$fork" -max_total_time=1800
fi

# In fork mode a crash ends the run, so the first bug would keep the budget from
# reaching any other one. libFuzzer already ignores timeouts and OOMs there;
# this treats crashes the same, so the run grinds for its whole budget and
# collects every input that fails rather than just the first. Prepended rather
# than appended because libFuzzer takes a flag's last occurrence, so an explicit
# override still wins.
set -- -ignore_crashes=1 "$@"

# Each step consumes what the previous one wrote, so they are invoked in order
# rather than declared as `depends`, which mise runs in parallel.
#
# `save-crashes` comes after the corpus has been measured: the inputs it adds
# crash the target by definition, so a `coverage` run that included them could
# not produce a profile, and the ceiling would go unrefreshed for the night.
#
# A failing step does not abandon the ones behind it either. The findings are
# worth committing whichever step broke, so every one that can still run does
# and the failure is re-raised at the end. They write through temporaries, so a
# failed step leaves the committed file it owns untouched.
failed=()

step() {
    if ! mise run "//rust/tests/fuzz:$1" "${@:2}"; then
        failed+=("$1")
    fi
}

step fuzz "$target" "$@"
step cmin "$target"
step coverage "$target"
step update-baseline "$target"
step save-crashes "$target"
step pack-corpus "$target"

if [ "${#failed[@]}" -gt 0 ]; then
    echo "error: step(s) failed: ${failed[*]}" >&2
    exit 1
fi
