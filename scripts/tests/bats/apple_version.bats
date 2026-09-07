#!/usr/bin/env bats

setup() {
    RELEASE_NAME=apple-client-1.0.0
    ASC_APP_ID=app-id
    ASC_PLATFORM=IOS
    APP_STATE=WAITING_FOR_REVIEW
    # shellcheck source=scripts/upload/apple-version.sh
    source "$BATS_TEST_DIRNAME/../../upload/apple-version.sh"
}

asc() {
    case "$1 $2" in
        "versions list")
            jq -n --arg state "$APP_STATE" '{data: [{id: "version-id", attributes: {appVersionState: $state, releaseType: "MANUAL"}}]}'
            ;;
        "versions view")
            echo '{"buildId":"build-id"}'
            ;;
        *) return 1 ;;
    esac
}

@test "only an identical manually released build is safe to reuse" {
    read_app_store_version
    [ "$version_phase" = submitted ]
    verify_app_store_build build-id

    run verify_app_store_build different-build
    [ "$status" -ne 0 ]

    release_type=AFTER_APPROVAL
    run verify_app_store_build build-id
    [ "$status" -ne 0 ]
}

@test "ready for review cannot be edited but can resume submission" {
    APP_STATE=READY_FOR_REVIEW
    read_app_store_version
    [ "$version_phase" = ready ]
}

@test "unexpected states fail instead of silently skipping preparation" {
    APP_STATE=PROCESSING_FOR_DISTRIBUTION
    run read_app_store_version
    [ "$status" -ne 0 ]
    [[ "$output" == *"unsupported state"* ]]
}
