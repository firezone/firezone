#!/usr/bin/env bash
#MISE description="Update the Elixir dead-code exceptions; pass --check to verify them"
# A deliberately conservative name-only check: comments, strings, captures, atoms,
# templates, and same-name functions in other modules all count as references.
# Framework callbacks without textual callers belong in the exception list.
set -euo pipefail

if [[ $# -gt 1 || (${1:-} != "" && ${1:-} != "--check") ]]; then
    echo "Usage: mise run //:elixir:dead-code [--check]" >&2
    exit 2
fi

cd "$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
export LC_ALL=C
baseline="elixir/dead-code-exceptions.json"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# git grep searches tracked working-tree files. An empty match set is valid;
# errors (such as unreadable files) must not silently update the baseline.
git_grep() {
    local status=0
    git grep "$@" || status=$?
    [[ $status -le 1 ]]
}

git_grep -I -n -E '^[[:space:]]*def[[:space:]]+[a-z_][a-zA-Z0-9_]*[!?]?' -- 'elixir/*.ex' 'elixir/*.exs' |
    awk -F: '{
        file = $1
        sub(/^[^:]*:[0-9]+:[[:space:]]*def[[:space:]]+/, "")
        match($0, /^[a-z_][a-zA-Z0-9_]*[!?]?/)
        print substr($0, RSTART, RLENGTH) "\t" file
    }' | sort -u >"$work/definitions"

# Do not let the baseline or the check's own test fixtures hide violations.
# Strip definition/spec heads so multiple clauses and specs aren't callers.
git_grep -I -h -E '[[:alpha:]_]' -- . ":!$baseline" \
    ':!mise-tasks/elixir/dead-code.sh' ':!scripts/tests/bats/elixir_dead_code.bats' |
    awk '{
        sub(/^[[:space:]]*def(p|macro|macrop|guard|guardp)?[[:space:]]+[a-z_][a-zA-Z0-9_]*[!?]?/, "")
        sub(/^[[:space:]]*@(spec|callback|macrocallback)[[:space:]]+[a-z_][a-zA-Z0-9_]*[!?]?/, "")
        while (match($0, /[a-zA-Z_][a-zA-Z0-9_]*[!?]?/)) {
            print substr($0, RSTART, RLENGTH)
            $0 = substr($0, RSTART + RLENGTH)
        }
    }' | sort -u >"$work/references"

cut -f1 "$work/definitions" | sort -u >"$work/names"
comm -23 "$work/names" "$work/references" >"$work/unused"
join -t $'\t' "$work/unused" "$work/definitions" |
    jq -Rn '[inputs | split("\t") | {file: .[1], name: .[0]}] | sort_by(.file, .name)' >"$work/actual.json"

if [[ ${1:-} == "--check" ]]; then
    if ! jq 'sort_by(.file, .name)' "$baseline" >"$work/expected.json" ||
        ! diff -u "$work/expected.json" "$work/actual.json"; then
        echo "Elixir dead code violation. If this is intended, run mise run //:elixir:dead-code to update the exception list and re-commit" >&2
        exit 1
    fi
else
    cp "$work/actual.json" "$baseline"
    echo "Updated $baseline"
fi
