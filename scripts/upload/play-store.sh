#!/usr/bin/env bash

# Uploads an AAB to the Google Play Console as a draft release on the given track.
#
# Required env vars:
#   ACCESS_TOKEN   - Short-lived Google OAuth access token, scope `androidpublisher`.
#                    In CI: produced by google-github-actions/auth via Workload Identity Federation.
#                    Locally: ACCESS_TOKEN=$(gcloud auth print-access-token \
#                                            --scopes=https://www.googleapis.com/auth/androidpublisher)
#   PACKAGE_NAME   - Application package name, e.g. dev.firezone.android
#   AAB_PATH       - Path to the .aab file to upload
#
# Optional env vars:
#   TRACK          - Release track. Default: production
#   RELEASE_STATUS - Release status. Default: draft

set -euo pipefail

: "${ACCESS_TOKEN:?ACCESS_TOKEN is required}"
: "${PACKAGE_NAME:?PACKAGE_NAME is required}"
: "${AAB_PATH:?AAB_PATH is required}"
TRACK="${TRACK:-production}"
RELEASE_STATUS="${RELEASE_STATUS:-draft}"

if [[ ! -f "$AAB_PATH" ]]; then
    echo "AAB not found at $AAB_PATH" >&2
    exit 1
fi

API="https://androidpublisher.googleapis.com/androidpublisher/v3/applications/$PACKAGE_NAME"
UPLOAD_API="https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/$PACKAGE_NAME"
AUTH_HEADER="Authorization: Bearer $ACCESS_TOKEN"

echo "Creating edit for $PACKAGE_NAME..."
EDIT_ID=$(curl --fail-with-body --silent --show-error --request POST \
    --header "$AUTH_HEADER" \
    --header "Content-Length: 0" \
    "$API/edits" | jq -r '.id')
echo "  Edit ID: $EDIT_ID"

echo "Uploading $AAB_PATH..."
VERSION_CODE=$(curl --fail-with-body --silent --show-error --request POST \
    --header "$AUTH_HEADER" \
    --header "Content-Type: application/octet-stream" \
    --data-binary "@$AAB_PATH" \
    "$UPLOAD_API/edits/$EDIT_ID/bundles?uploadType=media" | jq -r '.versionCode')
echo "  Uploaded versionCode: $VERSION_CODE"

echo "Assigning versionCode $VERSION_CODE to '$TRACK' track ($RELEASE_STATUS)..."
TRACK_BODY=$(jq -nc \
    --arg track "$TRACK" \
    --arg vc "$VERSION_CODE" \
    --arg status "$RELEASE_STATUS" \
    '{track: $track, releases: [{versionCodes: [$vc], status: $status}]}')
curl --fail-with-body --silent --show-error --request PUT \
    --header "$AUTH_HEADER" \
    --header "Content-Type: application/json" \
    --data "$TRACK_BODY" \
    "$API/edits/$EDIT_ID/tracks/$TRACK" >/dev/null

echo "Committing edit $EDIT_ID..."
curl --fail-with-body --silent --show-error --request POST \
    --header "$AUTH_HEADER" \
    --header "Content-Length: 0" \
    "$API/edits/$EDIT_ID:commit" >/dev/null

echo "Done. $PACKAGE_NAME versionCode $VERSION_CODE uploaded as $RELEASE_STATUS on '$TRACK' track."
