#!/usr/bin/env bats

setup() {
    export ASC_PLATFORM=IOS VERSION_ID=ios-version
    export REVIEW_DIR="$BATS_TEST_TMPDIR/review"
    mkdir -p "$REVIEW_DIR"
    echo 'Reviewer instructions' > "$REVIEW_DIR/notes.txt"
    echo 'screenshot content' > "$REVIEW_DIR/sign-in.png"
    echo '{"IOS":{"notes":"notes.txt","attachments":["sign-in.png"]}}' > "$REVIEW_DIR/manifest.json"
    echo '{"data":[]}' > "$REVIEW_DIR/attachments.json"
    echo 'Old notes' > "$REVIEW_DIR/remote-notes.txt"
    export -f asc
}

asc() {
    echo "$*" >> "$REVIEW_DIR/calls"
    case "$2" in
        details-for-version)
            jq -n --rawfile notes "$REVIEW_DIR/remote-notes.txt" '{data:{id:"review-detail",attributes:{notes:($notes | rtrimstr("\n"))}}}'
            ;;
        details-update)
            [[ "$3" == --id && "$4" == review-detail && "$5" == --notes && "$7" == --output ]]
            printf '%s' "$6" > "$REVIEW_DIR/remote-notes.txt"
            ;;
        attachments-list) cat "$REVIEW_DIR/attachments.json" ;;
        attachments-upload)
            [[ "${FAIL_UPLOAD:-false}" != true ]] || return 1
            local checksum name
            name=$(basename "$6")
            read -r checksum _ < <(md5sum "$6")
            jq -n --arg name "$name" --arg checksum "$checksum" \
                '{data:{id:"uploaded",attributes:{fileName:$name,sourceFileChecksum:$checksum,assetDeliveryState:{state:"COMPLETE"}}}}' > "$REVIEW_DIR/upload.json"
            jq --slurpfile upload "$REVIEW_DIR/upload.json" '.data += [$upload[0].data]' "$REVIEW_DIR/attachments.json" > "$REVIEW_DIR/next.json"
            mv "$REVIEW_DIR/next.json" "$REVIEW_DIR/attachments.json"
            cat "$REVIEW_DIR/upload.json"
            ;;
        attachments-delete)
            jq --arg id "$4" '.data |= map(select(.id != $id))' "$REVIEW_DIR/attachments.json" > "$REVIEW_DIR/next.json"
            mv "$REVIEW_DIR/next.json" "$REVIEW_DIR/attachments.json"
            ;;
        *) return 1 ;;
    esac
}

@test "sync reviewer inputs without changing credentials and skip identical reruns" {
    run bash "$BATS_TEST_DIRNAME/../../upload/apple-review.sh" "$REVIEW_DIR/manifest.json"
    [ "$status" -eq 0 ]
    [ "$(< "$REVIEW_DIR/remote-notes.txt")" = 'Reviewer instructions' ]
    jq -e '.data | length == 1' "$REVIEW_DIR/attachments.json"

    : > "$REVIEW_DIR/calls"
    run bash "$BATS_TEST_DIRNAME/../../upload/apple-review.sh" "$REVIEW_DIR/manifest.json"
    [ "$status" -eq 0 ]
    ! grep -Eq 'details-update|attachments-upload|attachments-delete' "$REVIEW_DIR/calls"
}

@test "replace incomplete and obsolete CI attachments but preserve manual attachments" {
    echo '{"data":[{"id":"partial","attributes":{"fileName":"firezone-ci-sign-in.png","assetDeliveryState":{"state":"AWAITING_UPLOAD"}}},{"id":"old","attributes":{"fileName":"firezone-ci-old.png"}},{"id":"manual","attributes":{"fileName":"manual.png"}}]}' > "$REVIEW_DIR/attachments.json"

    run bash "$BATS_TEST_DIRNAME/../../upload/apple-review.sh" "$REVIEW_DIR/manifest.json"
    [ "$status" -eq 0 ]
    jq -e '[.data[].id] | sort == ["manual","uploaded"]' "$REVIEW_DIR/attachments.json"
}

@test "failed uploads preserve previous attachments" {
    export FAIL_UPLOAD=true
    echo '{"data":[{"id":"old","attributes":{"fileName":"firezone-ci-sign-in.png"}}]}' > "$REVIEW_DIR/attachments.json"

    run bash "$BATS_TEST_DIRNAME/../../upload/apple-review.sh" "$REVIEW_DIR/manifest.json"
    [ "$status" -ne 0 ]
    ! grep -q attachments-delete "$REVIEW_DIR/calls"
}

@test "missing screenshots fail before changing reviewer information" {
    echo '{"IOS":{"notes":"notes.txt","attachments":["missing.png"]}}' > "$REVIEW_DIR/manifest.json"

    run bash "$BATS_TEST_DIRNAME/../../upload/apple-review.sh" "$REVIEW_DIR/manifest.json"
    [ "$status" -ne 0 ]
    [ ! -f "$REVIEW_DIR/calls" ]
}
