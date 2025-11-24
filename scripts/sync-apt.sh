#!/usr/bin/env bash

# Shell script for syncing the APT repository metadata from a set of `.deb` files.
#
# This script maintains two release channels: stable and preview.
# It expects the `.deb` files for these channels to be in the `pool-stable` and `pool-preview` directories.
# To add new packages to the repository, upload them to the `import-stable` and `import-preview` directories NOT to the `pool-` directories.
# The `pool-` directories are referenced by the live repository metadata and the files in there need to atomically change with the metadata.

set -euo pipefail
shopt -s globstar

COMPONENT="main"
WORK_DIR="$(mktemp -d)"
DISTS_DIR="${WORK_DIR}/dists"

if [ -z "${AZURERM_ARTIFACTS_CONNECTION_STRING:-}" ]; then
    echo "Error: AZURERM_ARTIFACTS_CONNECTION_STRING not set"
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
    POOL_DIR="${WORK_DIR}/pool-${DISTRIBUTION}"
    IMPORT_DIR="${WORK_DIR}/import-${DISTRIBUTION}"

    mkdir --parents "${POOL_DIR}"
    mkdir --parents "${IMPORT_DIR}"

    echo "Downloading existing packages for distribution $DISTRIBUTION..."

    az storage blob download-batch \
        --destination "${WORK_DIR}" \
        --source apt \
        --pattern "pool-${DISTRIBUTION}/*.deb" \
        --connection-string "${AZURERM_ARTIFACTS_CONNECTION_STRING}" \
        2>&1 | grep -v "WARNING" || true

    echo "Downloading import packages for distribution $DISTRIBUTION..."

    az storage blob download-batch \
        --destination "${WORK_DIR}" \
        --source apt \
        --pattern "import-${DISTRIBUTION}/*.deb" \
        --connection-string "${AZURERM_ARTIFACTS_CONNECTION_STRING}" \
        2>&1 | grep -v "WARNING" || true

    if [ "$(ls -A "${IMPORT_DIR}")" ]; then
        echo "Normalizing package names..."

        for deb in "${IMPORT_DIR}"/**; do
            if [[ ! "$deb" == *.deb ]]; then
                continue
            fi

            if [ -f "$deb" ]; then
                # Extract metadata from the .deb file
                PACKAGE=$(dpkg-deb -f "$deb" Package 2>/dev/null)
                VERSION=$(dpkg-deb -f "$deb" Version 2>/dev/null)
                ARCH=$(dpkg-deb -f "$deb" Architecture 2>/dev/null)

                # Skip if any field is missing
                if [ -z "$PACKAGE" ] || [ -z "$VERSION" ] || [ -z "$ARCH" ]; then
                    echo "Warning: Could not extract metadata from $(basename "$deb"), skipping"
                    continue
                fi

                # Construct the proper filename
                NORMALIZED_NAME="${PACKAGE}_${VERSION}_${ARCH}.deb"

                echo "Importing $(basename "$deb") as ${NORMALIZED_NAME}"
                mv --force "$deb" "${POOL_DIR}/${NORMALIZED_NAME}"
            fi
        done
    fi

    if [ -z "$(ls -A "${POOL_DIR}")" ]; then
        echo "No packages for distribution ${DISTRIBUTION}"

        continue
    fi

    echo "Detecting architectures..."
    ARCHITECTURES=$(for deb in "${POOL_DIR}"/*.deb; do dpkg-deb -f "$deb" Architecture 2>/dev/null; done | sort -u | tr '\n' ' ') || true

    echo "Found: ${ARCHITECTURES}"

    echo "Generating metadata..."
    mkdir -p "${DISTS_DIR}/${DISTRIBUTION}/${COMPONENT}"

    cd "$WORK_DIR"

    for ARCH in $ARCHITECTURES; do
        BINARY_DIR="${DISTS_DIR}/${DISTRIBUTION}/${COMPONENT}/binary-${ARCH}"
        mkdir -p "${BINARY_DIR}"

        apt-ftparchive packages --arch "${ARCH}" "pool-${DISTRIBUTION}" >"${BINARY_DIR}/Packages"
        gzip -k -f "${BINARY_DIR}/Packages"

        cat >"${BINARY_DIR}/Release" <<EOF
Archive: ${DISTRIBUTION}
Component: ${COMPONENT}
Architecture: ${ARCH}
EOF
    done

    cd "${DISTS_DIR}/${DISTRIBUTION}"
    cat >Release <<EOF
Origin: Firezone
Label: Firezone
Suite: ${DISTRIBUTION}
Codename: ${DISTRIBUTION}
Architectures: ${ARCHITECTURES}
Components: ${COMPONENT}
Description: Firezone APT Repository
Date: $(date -R -u)
EOF

    apt-ftparchive release . >>Release

    gpg --default-key "${GPG_KEY_ID}" -abs -o Release.gpg Release
    gpg --default-key "${GPG_KEY_ID}" --clearsign -o InRelease Release

    # Upload new pool directory
    az storage blob upload-batch \
        --destination apt \
        --destination-path "pool-${DISTRIBUTION}" \
        --source "${POOL_DIR}" \
        --connection-string "${AZURERM_ARTIFACTS_CONNECTION_STRING}" \
        --overwrite \
        --output table
done

echo "Uploading metadata..."
az storage blob upload-batch \
    --destination apt \
    --source "${DISTS_DIR}" \
    --destination-path dists \
    --connection-string "${AZURERM_ARTIFACTS_CONNECTION_STRING}" \
    --overwrite \
    --output table

# Delete import files
az storage blob delete-batch \
    --source apt \
    --pattern "import-*/*.deb" \
    --connection-string "${AZURERM_ARTIFACTS_CONNECTION_STRING}" \
    --output table
