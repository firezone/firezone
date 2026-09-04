#!/usr/bin/env bash

set -euo pipefail

readonly COMMAND="${1:?Usage: play-store.sh <inspect|internal|production>}"
: "${VERSION_NAME:?VERSION_NAME is required}"
: "${SOURCE_SHA:?SOURCE_SHA is required}"
: "${GPLAY_SERVICE_ACCOUNT_JSON:?GPLAY_SERVICE_ACCOUNT_JSON is required}"

readonly PACKAGE_NAME="dev.firezone.android"
readonly INTERNAL_TRACK="internal"
readonly PRODUCTION_TRACK="production"
readonly CHANGELOG_URL="https://www.firezone.dev/changelog#tab-android"
readonly PUBLISHER_API="https://androidpublisher.googleapis.com/androidpublisher/v3/applications/$PACKAGE_NAME"
readonly RELEASE_NAME="$VERSION_NAME@$SOURCE_SHA"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
readonly REPO_ROOT
mapfile -t SCREENSHOTS < "$REPO_ROOT/kotlin/android/screenshots/play-store.txt"
readonly -a SCREENSHOTS

case "$COMMAND" in
    inspect | internal | production) ;;
    *)
        echo "Unknown command: $COMMAND" >&2
        exit 1
        ;;
esac

export GPLAY_NO_UPDATE=1
edit_id=""
committed=false
internal_version_code=""

cleanup() {
    if [[ -n "$edit_id" && "$committed" != true ]]; then
        echo "Discarding uncommitted Google Play edit $edit_id; published releases are unchanged..."
        gplay edits delete --package "$PACKAGE_NAME" --edit "$edit_id" --confirm || true
    fi
}
trap cleanup EXIT

create_edit() {
    local edit

    echo "Opening Google Play edit transaction..."
    edit=$(gplay edits create --package "$PACKAGE_NAME")
    edit_id=$(jq -er '.id' <<< "$edit")
    echo "Opened edit $edit_id."
}

find_internal_release() {
    local internal

    echo "Finding the exact published internal release $RELEASE_NAME..."
    internal=$(gplay tracks releases list \
        --package "$PACKAGE_NAME" \
        --track "$INTERNAL_TRACK")

    internal_version_code=$(jq -er --arg name "$RELEASE_NAME" '
        first(.releases[]?
            | select(.releaseName == $name)
            | .activeArtifacts[]?.versionCode)
        | tostring' <<< "$internal")
    echo "Found $RELEASE_NAME with versionCode $internal_version_code."
}

update_track() {
    local track=$1
    local version_code=$2
    local releases

    echo "Creating or replacing the $track release..."
    releases=$(jq --compact-output --null-input \
        --arg name "$RELEASE_NAME" \
        --arg version_code "$version_code" \
        --arg changelog "$CHANGELOG_URL" \
        '[{
            name: $name,
            versionCodes: [$version_code],
            status: "completed",
            releaseNotes: [{language: "en-US", text: $changelog}]
        }]')
    gplay tracks update \
        --package "$PACKAGE_NAME" \
        --edit "$edit_id" \
        --track "$track" \
        --releases "$releases"
}

commit_edit() {
    : "${ACCESS_TOKEN:?ACCESS_TOKEN is required to commit the Google Play edit}"

    echo "Committing Google Play edit $edit_id..."
    # `gplay` 0.9.2 cannot set `changesInReviewBehavior`.
    curl --fail-with-body --silent --show-error \
        --request POST \
        --header "Authorization: Bearer $ACCESS_TOKEN" \
        --header "Content-Length: 0" \
        "$PUBLISHER_API/edits/$edit_id:commit?changesInReviewBehavior=ERROR_IF_IN_REVIEW" \
        >/dev/null
    committed=true
}

publish_internal() {
    local bundles bundle_hash upload version_code

    : "${AAB_PATH:?AAB_PATH is required}"
    if [[ ! -s "$AAB_PATH" ]]; then
        echo "Missing Android App Bundle: $AAB_PATH" >&2
        exit 1
    fi

    create_edit

    echo "Finding an existing upload of $AAB_PATH..."
    read -r bundle_hash _ < <(sha256sum "$AAB_PATH")
    bundles=$(gplay bundles list --package "$PACKAGE_NAME" --edit "$edit_id")
    version_code=$(jq -r --arg hash "$bundle_hash" '
        first(.bundles[]?
            | select(((.sha256 // "") | ascii_downcase) == $hash)
            | .versionCode) // empty' <<< "$bundles")
    if [[ -z "$version_code" ]]; then
        echo "Uploading $AAB_PATH..."
        upload=$(gplay bundles upload \
            --package "$PACKAGE_NAME" \
            --edit "$edit_id" \
            --file "$AAB_PATH")
        version_code=$(jq -er '.versionCode' <<< "$upload")
    else
        echo "Reusing uploaded versionCode $version_code."
    fi

    update_track "$INTERNAL_TRACK" "$version_code"

    echo "Validating edit $edit_id..."
    gplay edits validate --package "$PACKAGE_NAME" --edit "$edit_id"

    if [[ "${GITHUB_ACTIONS:-false}" != true || "${GITHUB_REF_NAME:-}" != main ]]; then
        echo "Validated $PACKAGE_NAME $RELEASE_NAME ($version_code) without committing."
        return
    fi

    commit_edit
    echo "Published $PACKAGE_NAME $RELEASE_NAME ($version_code) to Google Play internal testing."
}

inspect_internal() {
    find_internal_release

    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        echo "version_code=$internal_version_code" >> "$GITHUB_OUTPUT"
    fi

    echo "Verified $PACKAGE_NAME $RELEASE_NAME ($internal_version_code) on Google Play internal testing."
}

submit_production() {
    local production screenshot screenshot_path

    if [[ "${GITHUB_ACTIONS:-false}" != true || "${GITHUB_REF_NAME:-}" != main ]]; then
        echo "Production submission is only allowed from main in GitHub Actions" >&2
        exit 1
    fi

    for screenshot in "${SCREENSHOTS[@]}"; do
        screenshot_path="$REPO_ROOT/$screenshot"
        if [[ ! -s "$screenshot_path" ]]; then
            echo "Missing store screenshot: $screenshot" >&2
            exit 1
        fi
    done

    find_internal_release
    create_edit

    production=$(gplay tracks get \
        --package "$PACKAGE_NAME" \
        --edit "$edit_id" \
        --track "$PRODUCTION_TRACK")
    if jq -e \
        --arg name "$RELEASE_NAME" \
        --arg version_code "$internal_version_code" \
        '(.releases // []) as $releases
        | ($releases | length) == 1
        and $releases[0].name == $name
        and $releases[0].status == "completed"
        and $releases[0].versionCodes == [$version_code]' \
        <<< "$production" >/dev/null; then
        echo "Production already contains $RELEASE_NAME ($internal_version_code)."
        return
    elif jq -e --arg version_code "$internal_version_code" \
        'any(.releases[]?.versionCodes[]?; . == $version_code)' \
        <<< "$production" >/dev/null; then
        echo "Production contains versionCode $internal_version_code in an unexpected release" >&2
        exit 1
    elif ! jq -e '
        (.releases // []) as $releases
        | (($releases | length) <= 1)
        and ((($releases | length) == 0) or $releases[0].status == "completed")' \
        <<< "$production" >/dev/null; then
        echo "Production has multiple releases or a release that is not completed" >&2
        exit 1
    fi

    echo "Replacing en-US phone screenshots..."
    gplay images delete-all \
        --package "$PACKAGE_NAME" \
        --edit "$edit_id" \
        --locale en-US \
        --type phoneScreenshots \
        --confirm

    for screenshot in "${SCREENSHOTS[@]}"; do
        screenshot_path="$REPO_ROOT/$screenshot"
        echo "Uploading $screenshot..."
        gplay images upload \
            --package "$PACKAGE_NAME" \
            --edit "$edit_id" \
            --locale en-US \
            --type phoneScreenshots \
            --file "$screenshot_path"
    done

    update_track "$PRODUCTION_TRACK" "$internal_version_code"

    echo "Validating edit $edit_id..."
    gplay edits validate --package "$PACKAGE_NAME" --edit "$edit_id"
    commit_edit

    echo "Submitted $PACKAGE_NAME $RELEASE_NAME ($internal_version_code) and its screenshots for review."
}

case "$COMMAND" in
    inspect) inspect_internal ;;
    internal) publish_internal ;;
    production) submit_production ;;
esac
