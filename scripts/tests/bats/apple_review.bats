#!/usr/bin/env bats

setup() {
    export ASC_PLATFORM=IOS VERSION_ID=ios-version
    export REVIEW_DIR="$BATS_TEST_TMPDIR/review"
    mkdir -p "$REVIEW_DIR"
    echo 'screenshot content' > "$REVIEW_DIR/sign-in.png"
    echo '{"data":[]}' > "$REVIEW_DIR/attachments.json"
    export -f asc
}

asc() {
    echo "$*" >> "$REVIEW_DIR/calls"
    case "$2" in
        details-for-version)
            echo '{"data":{"id":"review-detail"}}'
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

@test "sync reviewer attachments without changing review details and skip identical reruns" {
    run bash "$BATS_TEST_DIRNAME/../../upload/apple-review.sh" "$REVIEW_DIR/sign-in.png"
    [ "$status" -eq 0 ]
    ! grep -q details-update "$REVIEW_DIR/calls"
    jq -e '.data | length == 1' "$REVIEW_DIR/attachments.json"

    : > "$REVIEW_DIR/calls"
    run bash "$BATS_TEST_DIRNAME/../../upload/apple-review.sh" "$REVIEW_DIR/sign-in.png"
    [ "$status" -eq 0 ]
    ! grep -Eq 'details-update|attachments-upload|attachments-delete' "$REVIEW_DIR/calls"
}

@test "replace incomplete and obsolete CI attachments but preserve manual attachments" {
    echo '{"data":[{"id":"partial","attributes":{"fileName":"firezone-ci-sign-in.png","assetDeliveryState":{"state":"AWAITING_UPLOAD"}}},{"id":"old","attributes":{"fileName":"firezone-ci-old.png"}},{"id":"manual","attributes":{"fileName":"manual.png"}}]}' > "$REVIEW_DIR/attachments.json"

    run bash "$BATS_TEST_DIRNAME/../../upload/apple-review.sh" "$REVIEW_DIR/sign-in.png"
    [ "$status" -eq 0 ]
    jq -e '[.data[].id] | sort == ["manual","uploaded"]' "$REVIEW_DIR/attachments.json"
}

@test "failed uploads preserve previous attachments" {
    export FAIL_UPLOAD=true
    echo '{"data":[{"id":"old","attributes":{"fileName":"firezone-ci-sign-in.png"}}]}' > "$REVIEW_DIR/attachments.json"

    run bash "$BATS_TEST_DIRNAME/../../upload/apple-review.sh" "$REVIEW_DIR/sign-in.png"
    [ "$status" -ne 0 ]
    ! grep -q attachments-delete "$REVIEW_DIR/calls"
}

@test "missing screenshots fail before changing reviewer information" {
    run bash "$BATS_TEST_DIRNAME/../../upload/apple-review.sh" "$REVIEW_DIR/missing.png"
    [ "$status" -ne 0 ]
    [ ! -f "$REVIEW_DIR/calls" ]
}
