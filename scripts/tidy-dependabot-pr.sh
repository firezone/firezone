#!/usr/bin/env bash
#
# Tidies a Dependabot pull request so its squash-merged commit message stays
# short and compliant. The parsing is done by the small Rust tool in
# rust/tools/tidy-dependabot-pr (pure text in, text out, unit-tested); this
# script fetches the PR and applies the result with the GitHub CLI.
#
# Environment (set by the workflow):
#   PR_NUMBER REPO   and GH_TOKEN for `gh`
#
# You can run the transform by hand to see what it would produce, without
# touching GitHub:
#   echo "$body" > /tmp/body.md
#   cargo run -p tidy-dependabot-pr --manifest-path rust/Cargo.toml -- body /tmp/body.md /tmp/new.md /tmp/comment.md
#   cargo run -p tidy-dependabot-pr --manifest-path rust/Cargo.toml -- title "$title"
set -euo pipefail

marker="<!-- tidy-dependabot-body:details -->"

pr="$(gh pr view "$PR_NUMBER" --repo "$REPO" --json body,title,url)"
body="$(jq -r '.body // ""' <<<"$pr")"
title="$(jq -r '.title // ""' <<<"$pr")"
url="$(jq -r '.url' <<<"$pr")"

# Dependabot re-edits the description in place when a newer version lands (or on
# `@dependabot recreate`), so this can run more than once per PR. Skip anything
# we've already tidied (or a non-Dependabot PR) so those runs are no-ops -- this
# is also what makes a manual `workflow_dispatch` run harmless on any PR.
case "$body" in
    *"<details>"* | *"dependabot-automerge"* | *"compatibility_score"* | *"Dependabot will resolve"*) ;;
    *)
        echo "Not a raw Dependabot body; nothing to do."
        exit 0
        ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tidy() { cargo run --quiet -p tidy-dependabot-pr --manifest-path "$repo_root/rust/Cargo.toml" -- "$@"; }

work="$(mktemp -d)"
printf '%s' "$body" >"$work/body.md"

tidy body "$work/body.md" "$work/new-body.md" "$work/comment.md"
new_title="$(tidy title "$title")"

edit=(--body "$(cat "$work/new-body.md")")
[ -n "$new_title" ] && edit+=(--title "$new_title")
gh pr edit "$url" "${edit[@]}"

# Upsert the details comment via its hidden marker so a rebase/recreate doesn't
# pile on duplicates.
if [ -f "$work/comment.md" ]; then
    id="$(gh api --paginate "repos/$REPO/issues/$PR_NUMBER/comments" \
        --jq ".[] | select(.body | contains(\"$marker\")) | .id" | head -n1 || true)"
    if [ -n "$id" ]; then
        jq -n --rawfile b "$work/comment.md" '{body: $b}' |
            gh api --method PATCH "repos/$REPO/issues/comments/$id" --input -
    else
        gh pr comment "$url" --body-file "$work/comment.md"
    fi
fi
