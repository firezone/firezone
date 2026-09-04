#!/usr/bin/env bash

set -euo pipefail

: "${AAB_PATH:?AAB_PATH is required}"
: "${VERSION_NAME:?VERSION_NAME is required}"
: "${GPLAY_SERVICE_ACCOUNT_JSON:?GPLAY_SERVICE_ACCOUNT_JSON is required}"

readonly PACKAGE_NAME="dev.firezone.android"
readonly INTERNAL_TRACK="internal"
readonly PRODUCTION_TRACK="production"
readonly CHANGELOG_URL="https://www.firezone.dev/changelog#tab-android"
readonly PUBLISHER_API="https://androidpublisher.googleapis.com/androidpublisher/v3/applications/$PACKAGE_NAME"
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

for screenshot in "${SCREENSHOTS[@]}"; do
    if [[ ! -s "$screenshot" ]]; then
        echo "Missing store screenshot: ${screenshot#"$REPO_ROOT/"}" >&2
        exit 1
    fi
done

if [[ ! -s "$AAB_PATH" ]]; then
    echo "Missing Android App Bundle: $AAB_PATH" >&2
    exit 1
fi

export GPLAY_NO_UPDATE=1
edit_id=""
committed=false
persist_draft=true
prepare_production_draft="${PREPARE_PRODUCTION_DRAFT:-false}"

if [[ "${GITHUB_ACTIONS:-false}" == true && "${GITHUB_REF_NAME:-}" != main ]]; then
    persist_draft=false
    prepare_production_draft=false
fi

cleanup() {
    if [[ -n "$edit_id" && "$committed" != true ]]; then
        echo "Discarding Google Play edit $edit_id..."
        gplay edits delete --package "$PACKAGE_NAME" --edit "$edit_id" --confirm || true
    fi
}
trap cleanup EXIT

echo "Creating Google Play edit..."
edit=$(gplay edits create --package "$PACKAGE_NAME")
edit_id=$(jq -er '.id' <<< "$edit")
echo "Created edit $edit_id."

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

update_draft() {
    local track=$1
    local current releases

    echo "Creating or replacing the $track draft..."
    current=$(gplay tracks get \
        --package "$PACKAGE_NAME" \
        --edit "$edit_id" \
        --track "$track")
    releases=$(jq -c \
        --arg name "$VERSION_NAME" \
        --argjson version_code "$version_code" \
        --arg changelog "$CHANGELOG_URL" \
        '(.releases // [] | map(select(.status != "draft"))) + [{
            name: $name,
            versionCodes: [$version_code],
            status: "draft",
            releaseNotes: [{language: "en-US", text: $changelog}]
        }]' <<< "$current")
    gplay tracks update \
        --package "$PACKAGE_NAME" \
        --edit "$edit_id" \
        --track "$track" \
        --releases "$releases"
}

update_draft "$INTERNAL_TRACK"
if [[ "$prepare_production_draft" == true ]]; then
    update_draft "$PRODUCTION_TRACK"
fi

echo "Validating edit $edit_id..."
gplay edits validate --package "$PACKAGE_NAME" --edit "$edit_id"

if [[ "$persist_draft" != true ]]; then
    echo "Validated $PACKAGE_NAME $VERSION_NAME ($version_code) without committing."
    exit 0
fi

echo "Committing draft release changes..."
: "${ACCESS_TOKEN:?ACCESS_TOKEN is required to commit the Google Play edit}"

# `gplay` 0.9.2 cannot set `changesInReviewBehavior`.
curl --fail-with-body --silent --show-error \
    --request POST \
    --header "Authorization: Bearer $ACCESS_TOKEN" \
    --header "Content-Length: 0" \
    "$PUBLISHER_API/edits/$edit_id:commit?changesInReviewBehavior=ERROR_IF_IN_REVIEW" \
    >/dev/null
committed=true

echo "Prepared $PACKAGE_NAME $VERSION_NAME ($version_code) as a Google Play draft."
