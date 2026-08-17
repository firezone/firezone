#!/usr/bin/env bash
#MISE description="Record the last coverage measurement as the target's committed baseline"
#MISE raw=true
#USAGE arg "<target>"
set -euo pipefail
cd "$(dirname "$0")/.."

target="${usage_target:?}"
baseline="expected-coverage/$target.json"

before="$(cat "$baseline" 2>/dev/null || echo null)"

# Write the baseline via a temporary so a failed measurement leaves the
# committed one intact rather than truncating it.
mkdir -p expected-coverage
temporary="$(mktemp "expected-coverage/.$target.XXXXXX")"
trap 'rm -f "$temporary"' EXIT
mise run -q //rust/tests/fuzz:coverage-summary "$target" >"$temporary"
mv "$temporary" "$baseline"
chmod 0644 "$baseline"

summarise() { jq -r 'if . == null then "(none)" else "\(.total - .covered) uncovered of \(.total)" end'; }

printf 'baseline: %s -> %s\n' \
    "$(summarise <<<"$before")" \
    "$(summarise <"$baseline")"
