#!/usr/bin/env bats

setup() {
    export GITHUB_REPOSITORY=firezone/firezone
    export RELEASE_NAME=apple-client-1.5.20
    export EXPECTED_SOURCE_SHA=1234567890123456789012345678901234567890
    export GITHUB_SERVER_URL=https://github.com
    export GITHUB_RUN_ID=123
    export RESPONSE="$BATS_TEST_TMPDIR/releases.json"
    export UPLOADED="$BATS_TEST_TMPDIR/uploaded.json"
    export GH_FAIL=false
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    cat >"$BATS_TEST_TMPDIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
    'api --paginate')
        [[ "$GH_FAIL" != true ]] || exit 1
        cat "$RESPONSE"
        ;;
    'release upload') cp "$4" "$UPLOADED" ;;
    *) exit 1 ;;
esac
MOCK
    chmod +x "$BATS_TEST_TMPDIR/bin/gh"
    jq -n --arg name "$RELEASE_NAME" --arg sha "$EXPECTED_SOURCE_SHA" \
        '[[{tag_name: $name, draft: true, target_commitish: $sha,
            assets: [{name: "client.ipa", digest: "sha256:abc", size: 42}]}]]' >"$RESPONSE"
    script="$BATS_TEST_DIRNAME/../../../mise-tasks/release/review-lock.sh"
}

@test "a new release can be built but cannot be locked" {
    echo '[[]]' >"$RESPONSE"
    run bash "$script" check
    [ "$status" -eq 0 ]
    run bash "$script" lock
    [ "$status" -ne 0 ]
    [ ! -f "$UPLOADED" ]
}

@test "API failure blocks building and submission" {
    export GH_FAIL=true
    run bash "$script" check
    [ "$status" -ne 0 ]
    run bash "$script" lock
    [ "$status" -ne 0 ]
    [ ! -f "$UPLOADED" ]
}

@test "a review lock on a later page prevents rebuilding and supports submission retries" {
    jq '[[{tag_name: "unrelated"}], [.[0][0] | .assets += [{name: "review-submission.json"}]]]' "$RESPONSE" >"$RESPONSE.tmp"
    mv "$RESPONSE.tmp" "$RESPONSE"
    run bash "$script" check
    [ "$status" -ne 0 ]
    [[ "$output" == *"locked for store review"* ]]
    run bash "$script" lock
    [ "$status" -eq 0 ]
    [ ! -f "$UPLOADED" ]
}

@test "an editable draft can be built and locked with its asset manifest" {
    run bash "$script" check
    [ "$status" -eq 0 ]
    run bash "$script" lock
    [ "$status" -eq 0 ]
    jq -e --arg sha "$EXPECTED_SOURCE_SHA" '
        .source_sha == $sha and .submission_run == "https://github.com/firezone/firezone/actions/runs/123"
        and .assets == [{name: "client.ipa", digest: "sha256:abc", size: 42}]' "$UPLOADED"
}

@test "a changed source cannot be locked" {
    export EXPECTED_SOURCE_SHA=other
    run bash "$script" lock
    [ "$status" -ne 0 ]
    [ ! -f "$UPLOADED" ]
}

@test "published releases cannot be rebuilt or locked" {
    jq '.[0][0].draft = false' "$RESPONSE" >"$RESPONSE.tmp"
    mv "$RESPONSE.tmp" "$RESPONSE"
    run bash "$script" check
    [ "$status" -ne 0 ]
    run bash "$script" lock
    [ "$status" -ne 0 ]
    [ ! -f "$UPLOADED" ]
}
