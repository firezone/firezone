#!/usr/bin/env bash

set -euo pipefail

readonly COMMAND="${1:?Usage: play-store.sh <internal|production>}"
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
readonly -a SCREENSHOTS=(
    "$REPO_ROOT/kotlin/android/screenshots/sign-in.png"
    "$REPO_ROOT/kotlin/android/screenshots/session-screen.png"
    "$REPO_ROOT/kotlin/android/screenshots/session-screen-favorites.png"
    "$REPO_ROOT/kotlin/android/screenshots/resource-details.png"
    "$REPO_ROOT/kotlin/android/screenshots/resource-details-internet.png"
    "$REPO_ROOT/kotlin/android/screenshots/device-details.png"
    "$REPO_ROOT/kotlin/android/screenshots/settings-general.png"
    "$REPO_ROOT/kotlin/android/screenshots/settings-advanced.png"
)

case "$COMMAND" in
    internal | production) ;;
    *)
        echo "Unknown command: $COMMAND" >&2
        exit 1
        ;;
esac

if [[ ! "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    echo "SOURCE_SHA must be a full lowercase Git commit SHA" >&2
    exit 1
fi

export GPLAY_NO_UPDATE=1
edit_id=""
committed=false

cleanup() {
    if [[ -n "$edit_id" && "$committed" != true ]]; then
        echo "Discarding Google Play edit $edit_id..."
        gplay edits delete --package "$PACKAGE_NAME" --edit "$edit_id" --confirm || true
    fi
}
trap cleanup EXIT

create_edit() {
    local edit

    echo "Creating Google Play edit..."
    edit=$(gplay edits create --package "$PACKAGE_NAME")
    edit_id=$(jq -er '.id' <<< "$edit")
    echo "Created edit $edit_id."
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
    local bundles bundle_hash matching_bundles upload version_code

    : "${AAB_PATH:?AAB_PATH is required}"
    if [[ ! -s "$AAB_PATH" ]]; then
        echo "Missing Android App Bundle: $AAB_PATH" >&2
        exit 1
    fi

    create_edit

    echo "Finding an existing upload of $AAB_PATH..."
    read -r bundle_hash _ < <(sha256sum "$AAB_PATH")
    bundles=$(gplay bundles list --package "$PACKAGE_NAME" --edit "$edit_id")
    matching_bundles=$(jq -c --arg hash "$bundle_hash" \
        '[.bundles[]? | select(((.sha256 // "") | ascii_downcase) == $hash)]' \
        <<< "$bundles")

    case $(jq 'length' <<< "$matching_bundles") in
        0)
            echo "Uploading $AAB_PATH..."
            upload=$(gplay bundles upload \
                --package "$PACKAGE_NAME" \
                --edit "$edit_id" \
                --file "$AAB_PATH")
            version_code=$(jq -er '.versionCode' <<< "$upload")
            ;;
        1)
            version_code=$(jq -er '.[0].versionCode' <<< "$matching_bundles")
            echo "Reusing uploaded versionCode $version_code."
            ;;
        *)
            echo "Multiple bundles have SHA-256 $bundle_hash" >&2
            exit 1
            ;;
    esac

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

submit_production() {
    local checkout_sha internal matching_releases production version_code screenshot

    if [[ "${GITHUB_ACTIONS:-false}" != true || "${GITHUB_REF_NAME:-}" != main ]]; then
        echo "Production submission is only allowed from main in GitHub Actions" >&2
        exit 1
    fi

    checkout_sha=$(git -C "$REPO_ROOT" rev-parse HEAD)
    if [[ "$checkout_sha" != "$SOURCE_SHA" ]]; then
        echo "The checkout SHA $checkout_sha does not match $SOURCE_SHA" >&2
        exit 1
    fi

    for screenshot in "${SCREENSHOTS[@]}"; do
        if [[ ! -s "$screenshot" ]]; then
            echo "Missing store screenshot: ${screenshot#"$REPO_ROOT/"}" >&2
            exit 1
        fi
    done

    create_edit

    echo "Finding the exact internal release $RELEASE_NAME..."
    internal=$(gplay tracks get \
        --package "$PACKAGE_NAME" \
        --edit "$edit_id" \
        --track "$INTERNAL_TRACK")
    matching_releases=$(jq -c --arg name "$RELEASE_NAME" \
        '[.releases[]? | select(
            .name == $name
            and .status == "completed"
            and (.versionCodes | length) == 1
        )]' <<< "$internal")

    case $(jq 'length' <<< "$matching_releases") in
        1) version_code=$(jq -er '.[0].versionCodes[0]' <<< "$matching_releases") ;;
        0)
            echo "No completed internal release matches $RELEASE_NAME" >&2
            exit 1
            ;;
        *)
            echo "Multiple completed internal releases match $RELEASE_NAME" >&2
            exit 1
            ;;
    esac

    production=$(gplay tracks get \
        --package "$PACKAGE_NAME" \
        --edit "$edit_id" \
        --track "$PRODUCTION_TRACK")
    if jq -e \
        --arg name "$RELEASE_NAME" \
        --arg version_code "$version_code" \
        '(.releases // []) as $releases
        | ($releases | length) == 1
        and $releases[0].name == $name
        and $releases[0].status == "completed"
        and $releases[0].versionCodes == [$version_code]' \
        <<< "$production" >/dev/null; then
        echo "Production already contains $RELEASE_NAME ($version_code)."
        return
    fi

    echo "Replacing en-US phone screenshots..."
    gplay images delete-all \
        --package "$PACKAGE_NAME" \
        --edit "$edit_id" \
        --locale en-US \
        --type phoneScreenshots \
        --confirm

    for screenshot in "${SCREENSHOTS[@]}"; do
        echo "Uploading ${screenshot#"$REPO_ROOT/"}..."
        gplay images upload \
            --package "$PACKAGE_NAME" \
            --edit "$edit_id" \
            --locale en-US \
            --type phoneScreenshots \
            --file "$screenshot"
    done

    update_track "$PRODUCTION_TRACK" "$version_code"

    echo "Validating edit $edit_id..."
    gplay edits validate --package "$PACKAGE_NAME" --edit "$edit_id"
    commit_edit

    echo "Submitted $PACKAGE_NAME $RELEASE_NAME ($version_code) and its screenshots for review."
}

case "$COMMAND" in
    internal) publish_internal ;;
    production) submit_production ;;
esac
