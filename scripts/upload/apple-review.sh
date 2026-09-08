#!/usr/bin/env bash

set -euo pipefail

: "${ASC_PLATFORM:?ASC_PLATFORM is required}"
: "${VERSION_ID:?VERSION_ID is required}"
screenshot=${1:?Usage: apple-review.sh <screenshot>}
if [[ ! -s "$screenshot" ]]; then
    echo "Missing reviewer input: $screenshot. Render screenshots in CI before creating the draft build." >&2
    exit 1
fi

detail=$(asc review details-for-version --version-id "$VERSION_ID" --output json)
detail_id=$(jq -er '.data.id' <<< "$detail")

attachments=$(asc review attachments-list --review-detail "$detail_id" --paginate --output json)
staging_dir=$(mktemp -d)
trap 'rm -rf "$staging_dir"' EXIT
name="firezone-ci-$(basename "$screenshot")"
read -r checksum _ < <(md5sum "$screenshot")
id=$(jq -r --arg name "$name" --arg checksum "$checksum" '
    first(.data[]? | select(.attributes.fileName == $name
        and ((.attributes.sourceFileChecksum // "") | ascii_downcase) == $checksum
        and (.attributes.assetDeliveryState.state == "COMPLETE"
            or .attributes.assetDeliveryState.state == "UPLOAD_COMPLETE")))
    | .id // empty' <<< "$attachments")
if [[ -z "$id" ]]; then
    echo "Uploading $ASC_PLATFORM reviewer attachment $name..."
    cp "$screenshot" "$staging_dir/$name"
    upload=$(asc review attachments-upload --review-detail "$detail_id" --file "$staging_dir/$name" --output json)
    id=$(jq -er '.data | select(.attributes.assetDeliveryState.state != "FAILED") | .id' <<< "$upload")
else
    echo "Reusing reviewer attachment $name."
fi

# Only the reserved prefix belongs to CI; leave manually attached files alone.
while IFS= read -r obsolete_id; do
    echo "Removing obsolete workflow-managed reviewer attachment $obsolete_id..."
    asc review attachments-delete --id "$obsolete_id" --confirm
done < <(jq -r --arg keep "$id" '.data[]?
    | select(.attributes.fileName | startswith("firezone-ci-"))
    | select(.id != $keep)
    | .id' <<< "$attachments")
