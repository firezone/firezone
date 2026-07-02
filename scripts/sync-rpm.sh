#!/usr/bin/env bash

# Shell script for syncing the RPM (DNF/YUM) repository metadata from a set of `.rpm` files.
#
# This is the RPM counterpart to `sync-apt.sh`. It maintains two release channels: stable and preview.
# To add new packages to the repository, upload them to the `import-stable` and `import-preview` directories NOT to the published channel directories.
#
# Unlike the APT layout, a DNF repository keeps the packages and the generated `repodata/` together in the directory pointed at by `baseurl`.
# Each channel is therefore published under `<distribution>/` (holding the `.rpm` files and their `repodata/`) and the packages in there need to atomically change with the metadata.

set -euo pipefail
shopt -s globstar

WORK_DIR="$(mktemp -d)"

if [ -z "${AZURE_STORAGE_ACCOUNT:-}" ]; then
    echo "Error: AZURE_STORAGE_ACCOUNT not set"
    exit 1
fi

if [ -z "${GPG_KEY_ID:-}" ]; then
    echo "Error: GPG_KEY_ID not set"
    exit 1
fi

cleanup() {
    rm -rf "${WORK_DIR}"
}

trap cleanup EXIT

for DISTRIBUTION in "stable" "preview"; do
    REPO_DIR="${WORK_DIR}/${DISTRIBUTION}"
    IMPORT_DIR="${WORK_DIR}/import-${DISTRIBUTION}"

    mkdir --parents "${REPO_DIR}"
    mkdir --parents "${IMPORT_DIR}"

    echo "Downloading existing packages for distribution $DISTRIBUTION..."

    az storage blob download-batch \
        --destination "${WORK_DIR}" \
        --source rpm \
        --pattern "${DISTRIBUTION}/*.rpm" \
        --auth-mode login \
        --account-name "${AZURE_STORAGE_ACCOUNT}" \
        2>&1 | grep -v "WARNING" || true

    echo "Downloading import packages for distribution $DISTRIBUTION..."

    az storage blob download-batch \
        --destination "${WORK_DIR}" \
        --source rpm \
        --pattern "import-${DISTRIBUTION}/*.rpm" \
        --auth-mode login \
        --account-name "${AZURE_STORAGE_ACCOUNT}" \
        2>&1 | grep -v "WARNING" || true

    if [ "$(ls -A "${IMPORT_DIR}")" ]; then
        echo "Normalizing package names..."

        for pkg in "${IMPORT_DIR}"/**; do
            if [[ ! "$pkg" == *.rpm ]]; then
                continue
            fi

            if [ -f "$pkg" ]; then
                # Derive the canonical NEVRA filename from the package metadata.
                NORMALIZED_NAME=$(rpm --query --package --queryformat '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}.rpm' "$pkg" 2>/dev/null)

                # Skip if the metadata could not be read
                if [ -z "$NORMALIZED_NAME" ]; then
                    echo "Warning: Could not extract metadata from $(basename "$pkg"), skipping"
                    continue
                fi

                echo "Importing $(basename "$pkg") as ${NORMALIZED_NAME}"
                mv --force "$pkg" "${REPO_DIR}/${NORMALIZED_NAME}"
            fi
        done
    fi

    if [ -z "$(ls -A "${REPO_DIR}")" ]; then
        echo "No packages for distribution ${DISTRIBUTION}"

        continue
    fi

    echo "Generating metadata..."
    createrepo_c "${REPO_DIR}"

    echo "Signing metadata..."
    gpg --default-key "${GPG_KEY_ID}" --detach-sign --armor "${REPO_DIR}/repodata/repomd.xml"

    # Upload the packages first so they are in place before the metadata that
    # references them goes live.
    echo "Uploading packages..."
    az storage blob upload-batch \
        --destination rpm \
        --destination-path "${DISTRIBUTION}" \
        --source "${REPO_DIR}" \
        --pattern "*.rpm" \
        --auth-mode login \
        --account-name "${AZURE_STORAGE_ACCOUNT}" \
        --overwrite \
        --output table

    echo "Uploading metadata..."
    az storage blob upload-batch \
        --destination rpm \
        --destination-path "${DISTRIBUTION}/repodata" \
        --source "${REPO_DIR}/repodata" \
        --auth-mode login \
        --account-name "${AZURE_STORAGE_ACCOUNT}" \
        --overwrite \
        --output table
done

# Delete import files
az storage blob delete-batch \
    --source rpm \
    --pattern "import-*/*.rpm" \
    --auth-mode login \
    --account-name "${AZURE_STORAGE_ACCOUNT}" \
    --output table
