#!/usr/bin/env bash
#MISE description="Check whether a release draft can be rebuilt"
#USAGE cmd "check" help="Fail if this release has a successful store submission" {
#USAGE     arg "<workflow>" help="Submission workflow filename"
#USAGE }

# Build and submission workflows must hold the same concurrency group.
set -euo pipefail

: "${usage_cmd:?Expected check}"
workflow=${usage_workflow:?Expected submission workflow filename}

# Listing distinguishes a missing release from an API or authentication failure.
release=$(gh api --paginate --slurp "repos/$GITHUB_REPOSITORY/releases?per_page=100" | jq -c --arg name "$RELEASE_NAME" '
    add | map(select(.tag_name == $name)) |
    if length > 1 then error("multiple matching releases") else .[0] end')

if [[ "$release" == null ]]; then
    exit 0
fi
jq -e '.draft == true' <<<"$release" >/dev/null

checkbox='- [x] Allow rebuilding this release'
if jq -e --arg checkbox "$checkbox" '(.body // "" | split("\n") | map(rtrimstr("\r"))) | any(. == $checkbox or . == ($checkbox | sub("\\[x\\]"; "[X]")))' <<<"$release" >/dev/null; then
    # Consume the override before updating the draft or starting any builds.
    jq --arg checkbox "$checkbox" '{tag_name, body: (.body | split("\n") | map(rtrimstr("\r")) | map(
        if . == $checkbox or . == ($checkbox | sub("\\[x\\]"; "[X]"))
        then "- [ ] Allow rebuilding this release" else . end) | join("\n"))}' <<<"$release" |
        gh api --method PATCH "repos/$GITHUB_REPOSITORY/releases/$(jq -r .id <<<"$release")" --input - >/dev/null
    exit 0
fi

created_at=$(jq -er .created_at <<<"$release")
runs=$(gh api --method GET --paginate --slurp "repos/$GITHUB_REPOSITORY/actions/workflows/$workflow/runs" \
    -f branch=main -f event=workflow_dispatch -f status=success -f "created=>=$created_at" -F per_page=100 |
    jq -r 'if type == "array" then .[].workflow_runs[] else error("Expected paginated workflow runs") end | [.head_sha, .html_url] | @tsv')
if [[ -z "$runs" ]]; then
    exit 0
fi

while IFS=$'\t' read -r sha url; do
    # Submission workflows run from main, which may differ from the draft's source.
    workflow_release=$(gh api "repos/$GITHUB_REPOSITORY/contents/.github/workflows/$workflow?ref=$sha" \
        -H 'Accept: application/vnd.github.raw+json' | sed -n 's/^  RELEASE_NAME: //p')
    if [[ -z "$workflow_release" ]]; then
        echo "::error::Cannot determine the release submitted by $url" >&2
        exit 1
    fi
    if [[ "$workflow_release" == "$RELEASE_NAME" ]]; then
        echo "::error::$RELEASE_NAME was submitted successfully: $url. To rebuild intentionally, check 'Allow rebuilding this release' in the draft release notes."
        exit 1
    fi
done <<<"$runs"
