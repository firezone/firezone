#!/usr/bin/env bash
#MISE description="Discover coverage, minimize, re-baseline and pack a fuzz corpus"
#MISE raw=true
#USAGE arg "<target>"
#USAGE flag "--workers <workers>"
#USAGE flag "--seconds <seconds>" default="1800"
#USAGE arg "[afl_args]…" var=#true
set -euo pipefail
cd "$(dirname "$0")/.."
target="${usage_target:?}"
workers="${usage_workers:-$(($(nproc) * 3 / 4))}"
[ "$workers" -gt 0 ] || workers=1
eval "set -- ${usage_afl_args:-}"

# Salvage completed phases even if discovery or minimization fails. Crashes
# enter the committed corpus after coverage so they cannot prevent measurement.
failed=()
step() {
    if ! mise run "//rust/tests/fuzz:$1" "${@:2}"; then
        failed+=("$1")
    fi
}
step fuzz "$target" --workers "$workers" --seconds "${usage_seconds:-1800}" "$@"
step cmin "$target"
step coverage "$target"
step update-baseline "$target"
step save-crashes "$target"
step pack-corpus "$target"
if [ "${#failed[@]}" -gt 0 ]; then
    echo "error: step(s) failed: ${failed[*]}" >&2
    exit 1
fi
