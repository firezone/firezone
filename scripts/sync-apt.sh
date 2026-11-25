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

if [ -z "${AZURE_STORAGE_ACCOUNT:-}" ]; then
    echo "Error: AZURE_STORAGE_ACCOUNT not set"
    exit 1
fi

if [ -z "${GPG_KEY_ID:-}" ]; then
    echo "Error: GPG_KEY_ID not set"
    exit 1
fi

if [ -z "${GPG_KEY_EXPIRY:-}" ]; then
    echo "Error: GPG_KEY_EXPIRY not set"
    exit 1
fi

cleanup() {
    rm -rf "${WORK_DIR}"
}

trap cleanup EXIT

# The expiry is set here rather than in the stored key, so renewing it only takes a change to `GPG_KEY_EXPIRY`.
GPG_KEY_FINGERPRINT=$(gpg --list-secret-keys --with-colons "${GPG_KEY_ID}" | awk -F: '$1 == "fpr" { print $10; exit }')
gpg --batch --quick-set-expire "${GPG_KEY_FINGERPRINT}" "${GPG_KEY_EXPIRY}"

# Ship the key as a package so clients pick up a renewed key through a normal upgrade, before the old one expires.
# The version follows the expiry, so a renewal publishes a new version and a re-run publishes nothing.
KEYRING_PACKAGE="firezone-archive-keyring_${GPG_KEY_EXPIRY//-/.}_all.deb"
KEYRING_DIR="${WORK_DIR}/keyring"

mkdir --parents "${KEYRING_DIR}/DEBIAN" "${KEYRING_DIR}/usr/share/keyrings"
gpg --export "${GPG_KEY_ID}" >"${KEYRING_DIR}/usr/share/keyrings/firezone-archive-keyring.gpg"
chmod 0644 "${KEYRING_DIR}/usr/share/keyrings/firezone-archive-keyring.gpg"

cat >"${KEYRING_DIR}/DEBIAN/control" <<EOF
Package: firezone-archive-keyring
Version: ${GPG_KEY_EXPIRY//-/.}
Architecture: all
Maintainer: Firezone, Inc. <support@firezone.dev>
Section: misc
Priority: optional
Description: GnuPG key of the Firezone APT repository
EOF

# Our install docs point `signed-by` at /etc/apt/keyrings/firezone.gpg, so keep that copy current too.
cat >"${KEYRING_DIR}/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e

if [ "$1" = "configure" ] && [ -e /etc/apt/keyrings/firezone.gpg ]; then
    install --mode 0644 /usr/share/keyrings/firezone-archive-keyring.gpg /etc/apt/keyrings/firezone.gpg
fi
EOF
chmod 0755 "${KEYRING_DIR}/DEBIAN/postinst"

dpkg-deb --root-owner-group --build "${KEYRING_DIR}" "${WORK_DIR}/${KEYRING_PACKAGE}"

load_blob_listing() {
    jq -e 'type == "array" and all(.[]; .name != null and .properties.contentLength != null)' "$POOL_LIST" >/dev/null || return 1

    local name size md5
    while IFS=$'\t' read -r name size md5; do
        REMOTE_SIZE["$name"]="$size"
        REMOTE_MD5["$name"]="$md5"
    done < <(jq -r '.[] | select(.name | endswith(".deb")) |
        [.name, .properties.contentLength, (.properties.contentSettings.contentMd5 // "")] | @tsv' "$POOL_LIST")
}

verify_release_checksums() {
    local metadata="$1" line digest size path actual in_sha=0
    local -A verified=()
    while IFS= read -r line; do
        if [[ "$line" == "SHA256:" ]]; then
            in_sha=1
            continue
        fi
        ((in_sha)) || continue
        [[ "$line" == " "* ]] || break
        read -r digest size path <<<"$line"
        path="${path#./}"
        [[ "$path" == "Release" ]] && continue # Older metadata includes its own pre-append checksum.
        [[ "$path" == main/* && "$path" != *..* && "$size" =~ ^[0-9]+$ ]] || return 1
        [[ -f "$metadata/$path" ]] || return 1
        [[ "$(stat -c %s "$metadata/$path")" == "$size" ]] || return 1
        actual="$(sha256sum "$metadata/$path")"
        [[ "${actual%% *}" == "$digest" ]] || return 1
        verified["$path"]=1
    done <"$metadata/Release"
    ((in_sha)) || return 1

    local arch name
    for arch in $OLD_ARCHITECTURES; do
        for name in Packages Packages.gz Release; do
            [[ -v verified["main/binary-$arch/$name"] ]] || return 1
        done
    done
}

load_records() {
    local index="$1" line filename="" size="" md5="" seen=0
    [[ -f "$index" ]] || return 1
    while IFS= read -r line; do
        if [[ -z "$line" ]]; then
            if ((seen)); then
                [[ "$filename" == "pool-$DISTRIBUTION/"* &&
                   "$size" =~ ^[0-9]+$ && "$md5" =~ ^[0-9a-fA-F]{32}$ ]] || return 1
                if [[ -v INDEX_SIZE["$filename"] ]]; then
                    [[ "${INDEX_SIZE[$filename]}" == "$size" &&
                       "${INDEX_MD5[$filename],,}" == "${md5,,}" ]] || return 1
                fi
                INDEX_SIZE["$filename"]="$size"
                INDEX_MD5["$filename"]="$md5"
            fi
            filename="" size="" md5="" seen=0
            continue
        fi
        seen=1
        case "$line" in
            "Filename: "*) filename="${line#Filename: }" ;;
            "Size: "*) size="${line#Size: }" ;;
            "MD5sum: "*) md5="${line#MD5sum: }" ;;
        esac
    done < <(cat "$index"; printf '\n\n')
}

check_index() {
    local metadata="$1" filename remote_md5
    local -A INDEX_SIZE=() INDEX_MD5=()
    OLD_ARCHITECTURES="$(sed -n 's/^Architectures: //p' "$metadata/Release")"
    [[ -n "$OLD_ARCHITECTURES" ]] || return 10
    grep -qx 'Components: main' "$metadata/Release" || return 10
    verify_release_checksums "$metadata" || return 10

    local arch
    for arch in $OLD_ARCHITECTURES; do
        load_records "$metadata/main/binary-$arch/Packages" || return 10
    done

    for filename in "${!INDEX_SIZE[@]}"; do
        [[ -v STAGED["$filename"] ]] && continue
        [[ -v REMOTE_SIZE["$filename"] ]] || { echo "Missing indexed package: $filename" >&2; return 20; }
        [[ "${REMOTE_SIZE[$filename]}" == "${INDEX_SIZE[$filename]}" ]] ||
            { echo "Wrong size for indexed package: $filename" >&2; return 20; }
        if [[ -n "${REMOTE_MD5[$filename]}" ]]; then
            remote_md5="$(printf '%s' "${REMOTE_MD5[$filename]}" | base64 -d | od -An -tx1 | tr -d ' \n')" || return 10
            [[ "${remote_md5,,}" == "${INDEX_MD5[$filename],,}" ]] ||
                { echo "Wrong hash for indexed package: $filename" >&2; return 20; }
        fi
    done
    for filename in "${!REMOTE_SIZE[@]}"; do
        [[ -v INDEX_SIZE["$filename"] || -v STAGED["$filename"] ]] || return 10
    done
    printf '%s' "$OLD_ARCHITECTURES"
}

merge_index() {
    local old="$1" new="$2" output="$3" old_all="$4"
    local line="" stanza="" filename=""
    [[ -s "$old" ]] || old="$old_all"
    : >"$output"
    if [[ -f "$old" ]]; then
        while IFS= read -r line; do
            if [[ -z "$line" ]]; then
                if [[ -n "$stanza" ]]; then
                    [[ -n "$filename" ]] || return 1
                    if [[ ! -v STAGED["$filename"] ]]; then
                        printf '%s\n' "$stanza" >>"$output"
                    fi
                fi
                stanza="" filename=""
                continue
            fi
            stanza+="$line"$'\n'
            [[ "$line" == "Filename: "* ]] && filename="${line#Filename: }"
        done < <(cat "$old"; printf '\n\n')
    fi
    cat "$new" >>"$output"
}

sync_distribution() {
    local DISTRIBUTION="$1"
    local POOL_DIR="${WORK_DIR}/pool-${DISTRIBUTION}"
    local IMPORT_DIR="${WORK_DIR}/import-${DISTRIBUTION}"
    local NEW_DIR="${WORK_DIR}/new-${DISTRIBUTION}"
    local UPLOAD_DIR="${WORK_DIR}/upload-${DISTRIBUTION}"
    local METADATA_DIR="${WORK_DIR}/previous-${DISTRIBUTION}/dists/${DISTRIBUTION}"
    local IMPORT_LIST="${WORK_DIR}/downloaded-imports-${DISTRIBUTION}"
    local POOL_LIST="${WORK_DIR}/pool-list-${DISTRIBUTION}.json"
    local OLD_ARCHITECTURES="" ARCHITECTURES="" STATUS=0
    local -A REMOTE_SIZE=() REMOTE_MD5=() STAGED=()

    mkdir --parents "${POOL_DIR}" "${IMPORT_DIR}" "${NEW_DIR}" "${UPLOAD_DIR}" "${METADATA_DIR}"
    : >"${IMPORT_LIST}"

    echo "Downloading import packages for distribution $DISTRIBUTION..."

    az storage blob download-batch \
        --destination "${WORK_DIR}" \
        --source apt \
        --pattern "import-${DISTRIBUTION}/*.deb" \
        --auth-mode login \
        --account-name "${AZURE_STORAGE_ACCOUNT}" \
        2>&1 | sed '/WARNING/d'

    if [ "$(ls -A "${IMPORT_DIR}")" ]; then
        echo "Normalizing package names..."

        for deb in "${IMPORT_DIR}"/**; do
            if [[ ! "$deb" == *.deb ]]; then
                continue
            fi

            printf '%s\0' "${deb#"${WORK_DIR}/"}" >>"${IMPORT_LIST}"

            if [ -f "$deb" ]; then
                # Extract metadata from the .deb file
                PACKAGE=$(dpkg-deb -f "$deb" Package 2>/dev/null)
                VERSION=$(dpkg-deb -f "$deb" Version 2>/dev/null)
                ARCH=$(dpkg-deb -f "$deb" Architecture 2>/dev/null)

                # Keep the import for a later run if its metadata cannot be read.
                if [ -z "$PACKAGE" ] || [ -z "$VERSION" ] || [ -z "$ARCH" ]; then
                    echo "Could not extract metadata from $(basename "$deb")" >&2
                    return 1
                fi

                # Construct the proper filename
                NORMALIZED_NAME="${PACKAGE}_${VERSION}_${ARCH}.deb"

                echo "Importing $(basename "$deb") as ${NORMALIZED_NAME}"
                cp --force "$deb" "${NEW_DIR}/${NORMALIZED_NAME}"
                STAGED["pool-${DISTRIBUTION}/${NORMALIZED_NAME}"]=1
            fi
        done
    fi

    echo "Listing published packages for distribution ${DISTRIBUTION}..."
    az storage blob list \
        --container-name apt \
        --prefix "pool-${DISTRIBUTION}/" \
        --num-results '*' \
        --auth-mode login \
        --account-name "${AZURE_STORAGE_ACCOUNT}" \
        --output json >"${POOL_LIST}"

    load_blob_listing
    if [[ ! -v REMOTE_SIZE["pool-${DISTRIBUTION}/${KEYRING_PACKAGE}"] ]]; then
        echo "Adding ${KEYRING_PACKAGE}"
        cp "${WORK_DIR}/${KEYRING_PACKAGE}" "${NEW_DIR}/"
        STAGED["pool-${DISTRIBUTION}/${KEYRING_PACKAGE}"]=1
    fi

    echo "Downloading published metadata for distribution ${DISTRIBUTION}..."
    az storage blob download-batch \
        --destination "${WORK_DIR}/previous-${DISTRIBUTION}" \
        --source apt \
        --pattern "dists/${DISTRIBUTION}/*" \
        --auth-mode login \
        --account-name "${AZURE_STORAGE_ACCOUNT}" \
        2>&1 | sed '/WARNING/d'

    local FAST_PATH=0
    if [ -f "${METADATA_DIR}/Release" ] && \
        gpg --batch --verify "${METADATA_DIR}/Release.gpg" "${METADATA_DIR}/Release" >/dev/null 2>&1 && \
        gpg --batch --decrypt --output "${WORK_DIR}/inrelease-${DISTRIBUTION}" "${METADATA_DIR}/InRelease" >/dev/null 2>&1 && \
        cmp --silent "${METADATA_DIR}/Release" "${WORK_DIR}/inrelease-${DISTRIBUTION}"; then
        if OLD_ARCHITECTURES=$(check_index "${METADATA_DIR}"); then
            FAST_PATH=1
        else
            STATUS=$?
            if ((STATUS == 20)); then
                return 1
            fi
        fi
    fi

    if ((FAST_PATH == 0)); then
        echo "Published metadata is incomplete; rebuilding from the full ${DISTRIBUTION} pool..."
        az storage blob download-batch \
            --destination "${WORK_DIR}" \
            --source apt \
            --pattern "pool-${DISTRIBUTION}/*.deb" \
            --auth-mode login \
            --account-name "${AZURE_STORAGE_ACCOUNT}" \
            2>&1 | sed '/WARNING/d'
    fi

    if [ "$(ls -A "${NEW_DIR}")" ]; then
        cp --force "${NEW_DIR}"/*.deb "${POOL_DIR}/"
    fi

    if ((FAST_PATH == 0)) && [ -z "$(ls -A "${POOL_DIR}")" ]; then
        echo "No packages for distribution ${DISTRIBUTION}"

        return
    fi

    echo "Detecting architectures..."
    ARCHITECTURES=$({
        tr ' ' '\n' <<<"${OLD_ARCHITECTURES}"
        for deb in "${POOL_DIR}"/*.deb; do
            [ -f "$deb" ] || continue
            dpkg-deb -f "$deb" Architecture 2>/dev/null
        done
    } | sed '/^$/d' | sort -u | tr '\n' ' ')

    echo "Found: ${ARCHITECTURES}"

    echo "Generating metadata..."
    mkdir -p "${DISTS_DIR}/${DISTRIBUTION}/${COMPONENT}"

    cd "$WORK_DIR"

    for ARCH in $ARCHITECTURES; do
        BINARY_DIR="${DISTS_DIR}/${DISTRIBUTION}/${COMPONENT}/binary-${ARCH}"
        mkdir -p "${BINARY_DIR}"

        if ((FAST_PATH)); then
            apt-ftparchive packages --arch "${ARCH}" "pool-${DISTRIBUTION}" >"${WORK_DIR}/new-Packages-${DISTRIBUTION}-${ARCH}"
            merge_index \
                "${METADATA_DIR}/${COMPONENT}/binary-${ARCH}/Packages" \
                "${WORK_DIR}/new-Packages-${DISTRIBUTION}-${ARCH}" \
                "${BINARY_DIR}/Packages" \
                "${METADATA_DIR}/${COMPONENT}/binary-all/Packages"
        else
            apt-ftparchive packages --arch "${ARCH}" "pool-${DISTRIBUTION}" >"${BINARY_DIR}/Packages"
        fi
        gzip -k -f "${BINARY_DIR}/Packages"

        cat >"${BINARY_DIR}/Release" <<EOF
Archive: ${DISTRIBUTION}
Component: ${COMPONENT}
Architecture: ${ARCH}
EOF
    done

    cd "${DISTS_DIR}/${DISTRIBUTION}"
    cat >"${WORK_DIR}/release-${DISTRIBUTION}" <<EOF
Origin: Firezone
Label: Firezone
Suite: ${DISTRIBUTION}
Codename: ${DISTRIBUTION}
Architectures: ${ARCHITECTURES}
Components: ${COMPONENT}
Description: Firezone APT Repository
Date: $(date -R -u)
EOF

    apt-ftparchive release . >>"${WORK_DIR}/release-${DISTRIBUTION}"
    mv "${WORK_DIR}/release-${DISTRIBUTION}" Release

    gpg --default-key "${GPG_KEY_ID}" -abs -o Release.gpg Release
    gpg --default-key "${GPG_KEY_ID}" --clearsign -o InRelease Release

    check_index "${DISTS_DIR}/${DISTRIBUTION}" >/dev/null

    local deb name remote_md5
    for deb in "${NEW_DIR}"/*.deb; do
        [[ -f "$deb" ]] || continue
        name="pool-${DISTRIBUTION}/${deb##*/}"
        if [[ -v REMOTE_SIZE["$name"] && "${REMOTE_SIZE[$name]}" == "$(stat -c %s "$deb")" &&
              -n "${REMOTE_MD5[$name]}" ]]; then
            remote_md5="$(printf '%s' "${REMOTE_MD5[$name]}" | base64 -d | od -An -tx1 | tr -d ' \n')"
            [[ "$remote_md5" == "$(md5sum "$deb" | cut -d ' ' -f 1)" ]] && continue
        fi
        ln --force "$deb" "${UPLOAD_DIR}/"
    done
    if [ "$(ls -A "${UPLOAD_DIR}")" ]; then
        az storage blob upload-batch \
            --destination apt \
            --destination-path "pool-${DISTRIBUTION}" \
            --source "${UPLOAD_DIR}" \
            --auth-mode login \
            --account-name "${AZURE_STORAGE_ACCOUNT}" \
            --overwrite \
            --output table
    fi
}

sync_distribution stable &
STABLE_PID=$!
sync_distribution preview &
PREVIEW_PID=$!

FAILED=0
wait "${STABLE_PID}" || FAILED=1
wait "${PREVIEW_PID}" || FAILED=1
if ((FAILED)); then
    exit 1
fi

echo "Uploading metadata..."
for DISTRIBUTION in stable preview; do
    az storage blob upload-batch \
        --destination apt \
        --source "${DISTS_DIR}/${DISTRIBUTION}/main" \
        --destination-path "dists/${DISTRIBUTION}/main" \
        --auth-mode login \
        --account-name "${AZURE_STORAGE_ACCOUNT}" \
        --overwrite \
        --output table

    for FILE in Release.gpg Release InRelease; do
        az storage blob upload \
            --container-name apt \
            --name "dists/${DISTRIBUTION}/${FILE}" \
            --file "${DISTS_DIR}/${DISTRIBUTION}/${FILE}" \
            --auth-mode login \
            --account-name "${AZURE_STORAGE_ACCOUNT}" \
            --overwrite \
            --output none
    done
done

# Publish the public key alongside, so a renewed key reaches clients on the next sync.
echo "Uploading public signing key..."
gpg --armor --export "${GPG_KEY_ID}" >"${WORK_DIR}/key.gpg"
az storage blob upload \
    --container-name apt \
    --name key.gpg \
    --file "${WORK_DIR}/key.gpg" \
    --auth-mode login \
    --account-name "${AZURE_STORAGE_ACCOUNT}" \
    --overwrite \
    --output table

# Delete only the import files this run downloaded. A release that copied its packages in after the download keeps them for the next sync.
for DISTRIBUTION in stable preview; do
    while IFS= read -r -d '' BLOB; do
        az storage blob delete \
            --container-name apt \
            --name "${BLOB}" \
            --auth-mode login \
            --account-name "${AZURE_STORAGE_ACCOUNT}" \
            --output table
    done <"${WORK_DIR}/downloaded-imports-${DISTRIBUTION}"
done
