#!/usr/bin/env bash
#
set -euo pipefail

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

    echo "Downloading packages for distribution $DISTRIBUTION..."

    az storage blob download-batch \
        --destination "${WORK_DIR}" \
        --source apt \
        --pattern "pool-${DISTRIBUTION}/*.deb" \
        --connection-string "${AZURERM_ARTIFACTS_CONNECTION_STRING}" \
        2>&1 | grep -v "WARNING" || true

    echo "Detecting architectures..."
    ARCHITECTURES=$(for deb in "${POOL_DIR}"/*.deb; do dpkg-deb -f "$deb" Architecture 2>/dev/null; done | sort -u | tr '\n' ' ') || true

    echo "Found: ${ARCHITECTURES}"

    echo "Generating metadata..."
    mkdir -p "${DISTS_DIR}/${DISTRIBUTION}/${COMPONENT}"

    for ARCH in $ARCHITECTURES; do
        BINARY_DIR="${DISTS_DIR}/${DISTRIBUTION}/${COMPONENT}/binary-${ARCH}"
        mkdir -p "${BINARY_DIR}"

        apt-ftparchive packages --arch "${ARCH}" "${POOL_DIR}/" >"${BINARY_DIR}/Packages"
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
done

echo "Uploading metadata..."
az storage blob upload-batch \
    --destination apt \
    --source "${DISTS_DIR}" \
    --destination-path dists \
    --connection-string "${AZURERM_ARTIFACTS_CONNECTION_STRING}" \
    --overwrite \
    --output table
