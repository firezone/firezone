#!/usr/bin/env bash
#MISE description="Check or lock a release draft for store review"

# Build and submission workflows must hold the same concurrency group.
set -euo pipefail

mode=${1:?Expected check or lock}
case "$mode" in
check | lock) ;;
*) exit 1 ;;
esac

# Listing distinguishes a missing release from an API or authentication failure.
release=$(gh api --paginate --slurp "repos/$GITHUB_REPOSITORY/releases?per_page=100" | jq -c --arg name "$RELEASE_NAME" '
    add | map(select(.tag_name == $name)) |
    if length > 1 then error("multiple matching releases") else .[0] end')

if [[ "$release" == null ]]; then
    if [[ "$mode" == check ]]; then
        exit 0
    fi
    echo "Cannot lock missing release $RELEASE_NAME" >&2
    exit 1
fi

jq -e '.draft == true' <<<"$release" >/dev/null
locked=$(jq 'any(.assets[]; .name == "review-submission.json")' <<<"$release")

if [[ "$mode" == check ]]; then
    if [[ "$locked" == true ]]; then
        echo "::error::$RELEASE_NAME is locked for store review. Cancel the store submissions before manually removing review-submission.json to rebuild."
        exit 1
    fi
    exit 0
fi

jq -e --arg sha "$EXPECTED_SOURCE_SHA" '.target_commitish == $sha' <<<"$release" >/dev/null
if [[ "$locked" == true ]]; then
    exit 0
fi

lock_dir=$(mktemp -d)
trap 'rm -rf "$lock_dir"' EXIT
jq --arg run "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID" '
    {source_sha: .target_commitish, submission_run: $run,
     assets: [.assets[] | {name, digest, size}]}' <<<"$release" >"$lock_dir/review-submission.json"

# Lock before contacting the store: a failed request may still have submitted.
gh release upload "$RELEASE_NAME" "$lock_dir/review-submission.json" --repo "$GITHUB_REPOSITORY"
