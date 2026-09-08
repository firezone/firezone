#!/usr/bin/env bats

setup() {
    export VERSION_NAME=1.5.14 SOURCE_SHA=source-sha
    export GPLAY_SERVICE_ACCOUNT_JSON=unused ACCESS_TOKEN=unused
    export GITHUB_ACTIONS=true GITHUB_REF_NAME=main
    export TRACK_FILE="$BATS_TEST_TMPDIR/track.json"
    export CALLS_FILE="$BATS_TEST_TMPDIR/calls"
    export -f gplay curl
}

gplay() {
    echo "$*" >> "$CALLS_FILE"
    case "$1 $2" in
        "tracks releases")
            echo '{"releases":[{"releaseName":"1.5.14@source-sha","activeArtifacts":[{"versionCode":42}]}]}'
            ;;
        "edits create") echo '{"id":"edit-id"}' ;;
        "tracks get") cat "$TRACK_FILE" ;;
        "tracks update")
            jq --null-input --argjson releases "${!#}" '{releases: $releases}' > "$TRACK_FILE"
            ;;
        "images upload" | "images delete-all" | "edits validate" | "edits delete") ;;
        *) return 1 ;;
    esac
}

curl() {
    echo "commit $*" >> "$CALLS_FILE"
}

@test "replace a production draft alongside the live release and skip a rerun" {
    echo '{"releases":[{"name":"Untitled release","status":"draft"},{"name":"1.5.13","status":"completed","versionCodes":["41"]}]}' > "$TRACK_FILE"

    run bash "$BATS_TEST_DIRNAME/../../upload/play-store.sh" production
    [ "$status" -eq 0 ]
    jq -e '.releases | length == 1' "$TRACK_FILE"
    jq -e '.releases[0] | .name == "1.5.14@source-sha" and .status == "completed" and .versionCodes == ["42"]' "$TRACK_FILE"
    grep -q 'changesInReviewBehavior=ERROR_IF_IN_REVIEW' "$CALLS_FILE"

    : > "$CALLS_FILE"
    run bash "$BATS_TEST_DIRNAME/../../upload/play-store.sh" production
    [ "$status" -eq 0 ]
    [[ "$output" == *"already contains"* ]]
    ! grep -Eq '^(commit|images|tracks update)' "$CALLS_FILE"
}

@test "reuse a draft already containing the selected artifact" {
    echo '{"releases":[{"name":"Untitled release","status":"draft","versionCodes":["42"]}]}' > "$TRACK_FILE"

    run bash "$BATS_TEST_DIRNAME/../../upload/play-store.sh" Intune
    [ "$status" -eq 0 ]
    grep -q '^tracks update' "$CALLS_FILE"
    grep -q '^commit' "$CALLS_FILE"
    ! grep -q '^images' "$CALLS_FILE"
}

@test "a draft does not bypass protection for staged or halted releases" {
    for release_status in inProgress halted; do
        jq -n --arg status "$release_status" '{releases: [{status: "draft"}, {status: $status, versionCodes: ["41"]}]}' > "$TRACK_FILE"

        run bash "$BATS_TEST_DIRNAME/../../upload/play-store.sh" production
        [ "$status" -ne 0 ]
        ! grep -Eq '^(commit|images|tracks update)' "$CALLS_FILE"
    done
}

@test "a draft does not bypass protection for multiple non-draft releases" {
    echo '{"releases":[{"status":"draft"},{"status":"completed","versionCodes":["40"]},{"status":"completed","versionCodes":["41"]}]}' > "$TRACK_FILE"

    run bash "$BATS_TEST_DIRNAME/../../upload/play-store.sh" production
    [ "$status" -ne 0 ]
    ! grep -Eq '^(commit|images|tracks update)' "$CALLS_FILE"
}
