#!/usr/bin/env bash

# Shell script for syncing the RPM (DNF/YUM) repository metadata from a set of `.rpm` files.
#
# It maintains two release channels: stable and preview.
# To add new packages to the repository, upload them to the `import-stable` and `import-preview` directories NOT to the published channel directories.
#
# A DNF repository keeps the packages and the generated `repodata/` together in the directory pointed at by `baseurl`.
# Each channel is therefore published under `<distribution>/` (holding the `.rpm` files and their `repodata/`) and the packages in there need to atomically change with the metadata.
#
# Every imported package is signed with the Firezone package-signing key so that clients work with DNF's default `gpgcheck=1`.
# The armoured public key is published at the repository root (`firezone.gpg`) for use as the `gpgkey` in the client `.repo` file.

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

# Configure `rpm --addsign` to sign non-interactively with our GnuPG key. The
# loopback pinentry mirrors the GnuPG config set up by the `setup-gpg` action.
cat >"${HOME}/.rpmmacros" <<EOF
%_signature gpg
%_gpg_name ${GPG_KEY_ID}
%__gpg /usr/bin/gpg
%__gpg_sign_cmd %{__gpg} --no-verbose --no-armor --batch --pinentry-mode loopback -u "%{_gpg_name}" --detach-sign --output %{__signature_filename} %{__plaintext_filename}
EOF

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
        echo "Normalizing and signing package names..."

        for pkg in "${IMPORT_DIR}"/**; do
            if [[ ! "$pkg" == *.rpm ]]; then
                continue
            fi

            if [ -f "$pkg" ]; then
                # Derive the canonical NEVRA filename from the package metadata.
                # `|| true` keeps a single unreadable package from aborting the
                # whole sync under `set -e`; the `-z` check below skips it instead.
                NORMALIZED_NAME=$(rpm --query --package --queryformat '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}.rpm' "$pkg" 2>/dev/null || true)

                # Skip if the metadata could not be read
                if [ -z "$NORMALIZED_NAME" ]; then
                    echo "Warning: Could not extract metadata from $(basename "$pkg"), skipping"
                    continue
                fi

                echo "Importing $(basename "$pkg") as ${NORMALIZED_NAME}"
                mv --force "$pkg" "${REPO_DIR}/${NORMALIZED_NAME}"

                # Sign so clients can verify with the default `gpgcheck=1`.
                rpm --addsign "${REPO_DIR}/${NORMALIZED_NAME}"
            fi
        done
    fi

    if [ -z "$(ls -A "${REPO_DIR}")" ]; then
        echo "No packages for distribution ${DISTRIBUTION}"

        continue
    fi

    echo "Generating metadata..."
    # Fixed metadata filenames (overwritten in place) so stale blobs do not
    # accumulate in the `repodata/` prefix on every sync.
    createrepo_c --simple-md-filenames "${REPO_DIR}"

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

# Publish the public key so it can be referenced as the `gpgkey` in the client `.repo`.
echo "Uploading public signing key..."
gpg --armor --export "${GPG_KEY_ID}" >"${WORK_DIR}/firezone.gpg"
az storage blob upload \
    --container-name rpm \
    --name firezone.gpg \
    --file "${WORK_DIR}/firezone.gpg" \
    --auth-mode login \
    --account-name "${AZURE_STORAGE_ACCOUNT}" \
    --overwrite \
    --output table

# Delete import files
az storage blob delete-batch \
    --source rpm \
    --pattern "import-*/*.rpm" \
    --auth-mode login \
    --account-name "${AZURE_STORAGE_ACCOUNT}" \
    --output table
