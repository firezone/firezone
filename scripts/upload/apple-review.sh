#!/usr/bin/env bash

set -euo pipefail

: "${ASC_PLATFORM:?ASC_PLATFORM is required}"
: "${VERSION_ID:?VERSION_ID is required}"
manifest=${1:?Usage: apple-review.sh <manifest>}
manifest_dir=$(dirname "$manifest")
platform=$(jq -er --arg platform "$ASC_PLATFORM" '.[$platform]' "$manifest")
notes_path=$(jq -er '.notes' <<< "$platform")
mapfile -t screenshots < <(jq -r '.attachments[]' <<< "$platform")

for path in "$notes_path" "${screenshots[@]}"; do
    if [[ ! -s "$manifest_dir/$path" ]]; then
        echo "Missing reviewer input: $path. Render screenshots in CI before creating the draft build." >&2
        exit 1
    fi
done

notes=$(< "$manifest_dir/$notes_path")
detail=$(asc review details-for-version --version-id "$VERSION_ID" --output json)
detail_id=$(jq -er '.data.id' <<< "$detail")
if [[ $(jq -r '.data.attributes.notes // ""' <<< "$detail") != "$notes" ]]; then
    echo "Updating $ASC_PLATFORM reviewer notes..."
    asc review details-update --id "$detail_id" --notes "$notes" --output json >/dev/null
fi

attachments=$(asc review attachments-list --review-detail "$detail_id" --paginate --output json)
staging_dir=$(mktemp -d)
trap 'rm -rf "$staging_dir"' EXIT
keep_ids='[]'

for screenshot in "${screenshots[@]}"; do
    path="$manifest_dir/$screenshot"
    name="firezone-ci-$(basename "$screenshot")"
    read -r checksum _ < <(md5sum "$path")
    id=$(jq -r --arg name "$name" --arg checksum "$checksum" '
        first(.data[]? | select(.attributes.fileName == $name
            and ((.attributes.sourceFileChecksum // "") | ascii_downcase) == $checksum
            and (.attributes.assetDeliveryState.state == "COMPLETE"
                or .attributes.assetDeliveryState.state == "UPLOAD_COMPLETE")))
        | .id // empty' <<< "$attachments")
    if [[ -z "$id" ]]; then
        echo "Uploading $ASC_PLATFORM reviewer attachment $name..."
        cp "$path" "$staging_dir/$name"
        upload=$(asc review attachments-upload --review-detail "$detail_id" --file "$staging_dir/$name" --output json)
        id=$(jq -er '.data | select(.attributes.assetDeliveryState.state != "FAILED") | .id' <<< "$upload")
    else
        echo "Reusing reviewer attachment $name."
    fi
    keep_ids=$(jq --arg id "$id" '. + [$id]' <<< "$keep_ids")
done

# Only the reserved prefix belongs to CI; leave manually attached files alone.
while IFS= read -r id; do
    echo "Removing obsolete workflow-managed reviewer attachment $id..."
    asc review attachments-delete --id "$id" --confirm
done < <(jq -r --argjson keep "$keep_ids" '.data[]?
    | select(.attributes.fileName | startswith("firezone-ci-"))
    | select(.id as $id | $keep | index($id) | not)
    | .id' <<< "$attachments")
