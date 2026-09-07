#!/usr/bin/env bash

version=${RELEASE_NAME#apple-client-}

read_app_store_version() {
    local target
    target=$(asc versions list --app "$ASC_APP_ID" --version "$version" --platform "$ASC_PLATFORM" --output json)
    version_id=$(jq -er 'if (.data | length) == 1 then .data[0].id else error("expected one App Store version") end' <<< "$target")
    release_type=$(jq -r '.data[0].attributes.releaseType' <<< "$target")
    state=$(jq -er '.data[0].attributes | if (.appVersionState // "") != "" then .appVersionState else .appStoreState end' <<< "$target")
    case "$state" in
        PREPARE_FOR_SUBMISSION | DEVELOPER_REJECTED | REJECTED | METADATA_REJECTED)
            version_phase=editable
            ;;
        READY_FOR_REVIEW)
            version_phase=ready
            ;;
        WAITING_FOR_REVIEW | IN_REVIEW | PENDING_DEVELOPER_RELEASE | READY_FOR_DISTRIBUTION | READY_FOR_SALE)
            version_phase=submitted
            ;;
        *)
            echo "$ASC_PLATFORM $version is in unsupported state $state; resolve it in App Store Connect before rerunning." >&2
            return 1
            ;;
    esac
    export version_phase
    echo "$ASC_PLATFORM $version: $state"
}

verify_app_store_build() {
    local details
    details=$(asc versions view --version-id "$version_id" --include-build --output json)
    if [[ "$release_type" != MANUAL ]] || ! jq -e --arg build_id "$1" '.buildId == $build_id' <<< "$details" >/dev/null; then
        echo "$ASC_PLATFORM $version must have the selected build attached and manual release enabled; inspect it in App Store Connect." >&2
        return 1
    fi
}
