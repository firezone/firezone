#!/usr/bin/env bash

# Shell script for syncing the APT repository metadata from a set of `.deb` files.
#
# This script maintains two release channels: stable and preview.
# It expects the `.deb` files for these channels to be in the `pool-stable` and `pool-preview` directories.
# To add new packages to the repository, upload them to the `import-stable` and `import-preview` directories NOT to the `pool-` directories.
# The `pool-` directories are referenced by the live repository metadata and the files in there need to atomically change with the metadata.
#
# Preview publishes every build, each under its own Debian revision so that a build never overwrites its predecessor at the same pool path.
# Superseded preview builds are pruned once no client is likely to still hold a `Packages` index describing them; see `prune_preview` below.

set -euo pipefail
shopt -s globstar

COMPONENT="main"
WORK_DIR="$(mktemp -d)"
DISTS_DIR="${WORK_DIR}/dists"

# How many superseded builds of a package stay in the preview pool. A `.deb`
# carries no build timestamp, so unlike the RPM channel this is a count rather
# than an age; it exists so a client that fetched its `Packages` index a while
# ago can still download what that index describes.
PREVIEW_KEEP_BUILDS=5

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

# Drop preview builds that no client can still be asking for, so the pool does
# not grow by one package per build and architecture forever.
#
# The newest build of every version is always kept: it is the one a release is
# promoted to `stable` from, which can happen long after the build itself.
prune_preview() {
    local pool_dir="$1"
    local index="${WORK_DIR}/preview-index"
    local keep key version

    # `<package>_<arch> <upstream version> <full version> <file>`, so the two
    # rules below can group by package and by version.
    for deb in "${pool_dir}"/*.deb; do
        key="$(dpkg-deb -f "$deb" Package)_$(dpkg-deb -f "$deb" Architecture)"
        version="$(dpkg-deb -f "$deb" Version)"

        printf '%s %s %s %s\n' "$key" "${version%-*}" "$version" "$deb"
    done >"${index}"

    keep=$(
        {
            sort -k1,1 -k2,2 -k3,3V "${index}" | awk '{ newest[$1 " " $2] = $4 } END { for (pkg in newest) print newest[pkg] }'
            sort -k1,1 -k3,3Vr "${index}" | awk -v keep="${PREVIEW_KEEP_BUILDS}" '++seen[$1] <= keep { print $4 }'
        } | sort --unique
    )

    while read -r _ _ _ deb; do
        if grep --quiet --line-regexp --fixed-strings "$deb" <<<"$keep"; then
            continue
        fi

        echo "Pruning $(basename "$deb")"
        rm --force "$deb"

        az storage blob delete \
            --container-name apt \
            --name "pool-preview/$(basename "$deb")" \
            --auth-mode login \
            --account-name "${AZURE_STORAGE_ACCOUNT}" \
            --output none
    done <"${index}"

    rm --force "${index}"
}

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
        --auth-mode login \
        --account-name "${AZURE_STORAGE_ACCOUNT}" \
        2>&1 | grep -v "WARNING" || true

    echo "Downloading import packages for distribution $DISTRIBUTION..."

    az storage blob download-batch \
        --destination "${WORK_DIR}" \
        --source apt \
        --pattern "import-${DISTRIBUTION}/*.deb" \
        --auth-mode login \
        --account-name "${AZURE_STORAGE_ACCOUNT}" \
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

    if [ "${DISTRIBUTION}" = "preview" ]; then
        echo "Pruning superseded preview builds..."

        prune_preview "${POOL_DIR}"
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
        --auth-mode login \
        --account-name "${AZURE_STORAGE_ACCOUNT}" \
        --overwrite \
        --output table
done

echo "Uploading metadata..."
az storage blob upload-batch \
    --destination apt \
    --source "${DISTS_DIR}" \
    --destination-path dists \
    --auth-mode login \
    --account-name "${AZURE_STORAGE_ACCOUNT}" \
    --overwrite \
    --output table

# Delete import files
az storage blob delete-batch \
    --source apt \
    --pattern "import-*/*.deb" \
    --auth-mode login \
    --account-name "${AZURE_STORAGE_ACCOUNT}" \
    --output table
