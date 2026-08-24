#!/usr/bin/env bash
#MISE description="Copy the screenshots a UI-test run attached to an xcresult into a directory"
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <xcresult> <output-directory>" >&2
    exit 1
fi

XCRESULT="$1"
OUTPUT_DIR="$2"
STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "${STAGING_DIR}"' EXIT

# Xcode signs the UI-test runner with the App Sandbox whatever the target's
# settings say, so the runner cannot write the images itself and every capture
# travels as a test attachment instead. The export names the files by UUID; the
# manifest maps them back to the names the tests gave them.
xcrun xcresulttool export attachments --path "${XCRESULT}" --output-path "${STAGING_DIR}"

manifest="${STAGING_DIR}/manifest.json"
if [ ! -f "${manifest}" ]; then
    echo "No attachment manifest in ${XCRESULT}" >&2
    exit 1
fi

mkdir -p "${OUTPUT_DIR}"

# XCTest hands back the name a test gave its attachment with an index and a
# UUID appended, so take those off to get the gallery's file name. Only the
# captures are taken, by the shape of that name: XCUITest attaches its own
# diagnostics beside them, and an empty run fails below.
copied=0
while IFS="$(printf '\t')" read -r exported suggested; do
    name="${suggested%.png}"
    name="${name%%_[0-9]*_*}"

    case "${name}" in
    *-light | *-dark) ;;
    *) continue ;;
    esac

    [ -e "${STAGING_DIR}/${exported}" ] || continue

    cp "${STAGING_DIR}/${exported}" "${OUTPUT_DIR}/${name}.png"
    echo "  ${name}.png"
    copied=$((copied + 1))
done < <(jq -r '
  .. | objects | select(has("exportedFileName"))
  | [.exportedFileName, (.suggestedHumanReadableName // .configuredName // empty)]
  | select(length == 2) | @tsv
' "${manifest}")

if [ "${copied}" -eq 0 ]; then
    echo "No screenshots in ${XCRESULT}; the attachments it holds are:" >&2
    jq -r '.. | objects | select(has("exportedFileName"))
      | (.suggestedHumanReadableName // .configuredName // .exportedFileName)' "${manifest}" >&2
    exit 1
fi

echo "Copied ${copied} screenshots to ${OUTPUT_DIR}"
