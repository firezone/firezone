#!/usr/bin/env bats

setup() {
    export GITHUB_REPOSITORY=firezone/firezone
    export RELEASE_NAME=apple-client-1.5.20
    export usage_cmd=check
    export usage_force=false
    export RESPONSE="$BATS_TEST_TMPDIR/releases.json"
    export ARTIFACTS="$BATS_TEST_TMPDIR/artifacts.json"
    export GH_FAIL=""
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    cat >"$BATS_TEST_TMPDIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
    *'/releases?per_page=100')
        [[ "$GH_FAIL" != releases ]] || exit 1
        cat "$RESPONSE"
        ;;
    *'/actions/artifacts '*)
        [[ "$GH_FAIL" != artifacts ]] || exit 1
        [[ "$*" == *"name=release-review-$RELEASE_NAME"* ]]
        cat "$ARTIFACTS"
        ;;
    *) exit 1 ;;
esac
MOCK
    chmod +x "$BATS_TEST_TMPDIR/bin/gh"
    jq -n --arg name "$RELEASE_NAME" '[[{tag_name: $name, draft: true}]]' >"$RESPONSE"
    echo '[{"artifacts": []}]' >"$ARTIFACTS"
    script="$BATS_TEST_DIRNAME/../../../mise-tasks/release/review-lock.sh"
}

review_lock() {
    jq -n --arg name "release-review-$RELEASE_NAME" \
        '[{artifacts: [{name: $name, workflow_run: {id: 123, head_branch: "main", head_sha: "submission-sha"}}]}]' >"$ARTIFACTS"
}

@test "a new release can be built" {
    echo '[[]]' >"$RESPONSE"
    run bash "$script"
    [ "$status" -eq 0 ]
}

@test "a draft without a review lock can be rebuilt" {
    run bash "$script"
    [ "$status" -eq 0 ]
}

@test "a review artifact blocks rebuilding without checking the run outcome or source" {
    review_lock
    run bash "$script"
    [ "$status" -ne 0 ]
    [[ "$output" == *"locked for review by https://github.com/firezone/firezone/actions/runs/123"* ]]
}

@test "an artifact for another release or branch does not block rebuilding" {
    review_lock
    jq '.[0].artifacts += [.[0].artifacts[0] | .name = "another-release"] | .[0].artifacts[0].workflow_run.head_branch = "feature"' "$ARTIFACTS" >"$ARTIFACTS.tmp"
    mv "$ARTIFACTS.tmp" "$ARTIFACTS"
    run bash "$script"
    [ "$status" -eq 0 ]
}

@test "a review artifact on a later page blocks rebuilding" {
    review_lock
    jq '[{artifacts: []}] + .' "$ARTIFACTS" >"$ARTIFACTS.tmp"
    mv "$ARTIFACTS.tmp" "$ARTIFACTS"
    run bash "$script"
    [ "$status" -ne 0 ]
    [[ "$output" == *"locked for review"* ]]
}

@test "force allows rebuilding a locked draft without removing its artifact" {
    review_lock
    run env usage_force=true GH_FAIL=artifacts bash "$script"
    [ "$status" -eq 0 ]
    run bash "$script"
    [ "$status" -ne 0 ]
}

@test "API failures block rebuilding" {
    for endpoint in releases artifacts; do
        run env GH_FAIL="$endpoint" bash "$script"
        [ "$status" -ne 0 ]
    done
}

@test "published releases cannot be rebuilt even with force" {
    jq '.[0][0].draft = false' "$RESPONSE" >"$RESPONSE.tmp"
    mv "$RESPONSE.tmp" "$RESPONSE"
    run env usage_force=true bash "$script"
    [ "$status" -ne 0 ]
}
