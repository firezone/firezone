#!/usr/bin/env bats

setup() {
    export GITHUB_REPOSITORY=firezone/firezone
    export RELEASE_NAME=apple-client-1.5.20
    export usage_cmd=check
    export usage_workflow=submit-apple-release.yml
    export RESPONSE="$BATS_TEST_TMPDIR/releases.json"
    export RUNS="$BATS_TEST_TMPDIR/runs.json"
    export PATCH="$BATS_TEST_TMPDIR/patch.json"
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
    *'--method PATCH '*)
        [[ "$GH_FAIL" != patch ]] || exit 1
        cat > "$PATCH"
        jq --slurpfile patch "$PATCH" '.[0][0].body = $patch[0].body' "$RESPONSE" > "$RESPONSE.tmp"
        mv "$RESPONSE.tmp" "$RESPONSE"
        ;;
    *'/runs '*)
        [[ "$GH_FAIL" != runs ]] || exit 1
        [[ "$*" == *'branch=main'* && "$*" == *'event=workflow_dispatch'* && "$*" == *'status=success'* ]]
        [[ "$*" == *'created=>=2026-09-01T00:00:00Z'* ]]
        cat "$RUNS"
        ;;
    *'/contents/'*)
        [[ "$GH_FAIL" != workflow ]] || exit 1
        if [[ "$*" == *'ref=other-release'* ]]; then
            echo '  RELEASE_NAME: apple-client-1.5.19'
        else
            printf '  RELEASE_NAME: %s\n' "$RELEASE_NAME"
        fi
        ;;
    *) exit 1 ;;
esac
MOCK
    chmod +x "$BATS_TEST_TMPDIR/bin/gh"
    jq -n --arg name "$RELEASE_NAME" \
        '[[{id: 123, tag_name: $name, draft: true, target_commitish: "draft-sha",
            created_at: "2026-09-01T00:00:00Z", body: "Release notes\n\n- [ ] Allow rebuilding this release"}]]' >"$RESPONSE"
    echo '[{"workflow_runs": []}]' >"$RUNS"
    script="$BATS_TEST_DIRNAME/../../../mise-tasks/release/review-lock.sh"
}

successful_submission() {
    echo '[{"workflow_runs": [{"head_sha": "submission-sha", "html_url": "https://github.com/firezone/firezone/actions/runs/123"}]}]' >"$RUNS"
}

check_override() {
    jq '.[0][0].body = "Release notes\r\n\r\n- [X] Allow rebuilding this release"' "$RESPONSE" >"$RESPONSE.tmp"
    mv "$RESPONSE.tmp" "$RESPONSE"
}

@test "a new release can be built" {
    echo '[[]]' >"$RESPONSE"
    run bash "$script"
    [ "$status" -eq 0 ]
}

@test "a draft without a successful submission can be rebuilt" {
    run bash "$script"
    [ "$status" -eq 0 ]
    [ ! -f "$PATCH" ]
}

@test "successful submission blocks rebuilding even from a different workflow commit" {
    successful_submission
    run bash "$script"
    [ "$status" -ne 0 ]
    [[ "$output" == *"was submitted successfully"* ]]
}

@test "successful submissions for other releases do not block rebuilding" {
    echo '[{"workflow_runs": [{"head_sha": "other-release", "html_url": "https://github.com/firezone/firezone/actions/runs/1"}]}]' >"$RUNS"
    run bash "$script"
    [ "$status" -eq 0 ]
}

@test "a matching submission on a later page blocks rebuilding" {
    successful_submission
    jq '[{workflow_runs: [{head_sha: "other-release", html_url: "https://github.com/firezone/firezone/actions/runs/1"}]}] + .' "$RUNS" >"$RUNS.tmp"
    mv "$RUNS.tmp" "$RUNS"
    run bash "$script"
    [ "$status" -ne 0 ]
    [[ "$output" == *"was submitted successfully"* ]]
}

@test "the checkbox overrides a successful submission exactly once" {
    successful_submission
    check_override
    run bash "$script"
    [ "$status" -eq 0 ]
    jq -e --arg name "$RELEASE_NAME" '. == {tag_name: $name, body: "Release notes\n\n- [ ] Allow rebuilding this release"}' "$PATCH"
    run bash "$script"
    [ "$status" -ne 0 ]
    [[ "$output" == *"was submitted successfully"* ]]
}

@test "API failures block rebuilding" {
    successful_submission
    for endpoint in releases runs workflow; do
        run env GH_FAIL="$endpoint" bash "$script"
        [ "$status" -ne 0 ]
    done
}

@test "failure to consume the override blocks rebuilding" {
    check_override
    run env GH_FAIL=patch bash "$script"
    [ "$status" -ne 0 ]
}

@test "an unreadable run response blocks rebuilding" {
    echo '{}' >"$RUNS"
    run bash "$script"
    [ "$status" -ne 0 ]
}

@test "published releases cannot be rebuilt even with the override checked" {
    check_override
    jq '.[0][0].draft = false' "$RESPONSE" >"$RESPONSE.tmp"
    mv "$RESPONSE.tmp" "$RESPONSE"
    run bash "$script"
    [ "$status" -ne 0 ]
    [ ! -f "$PATCH" ]
}
