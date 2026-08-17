#!/usr/bin/env bash

set -euo pipefail

readonly default_store=/etc/tpm2_pkcs11
readonly default_state_dir=/etc/firezone
readonly store=${FIREZONE_TPM2_PKCS11_STORE:-$default_store}
readonly state_dir=${FIREZONE_TPM2_PKCS11_STATE_DIR:-$default_state_dir}
readonly pin_file="$state_dir/pkcs11-pin"
readonly so_pin_file="$state_dir/pkcs11-so-pin"
readonly primary_id_file="$state_dir/tpm2-pkcs11-primary-id"
readonly token_label=Firezone
readonly key_label=device-trust
readonly key_id=666972657a6f6e65

usage() {
    echo "Usage: sudo $0 DEVICE_ID [CSR_PATH]" >&2
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
    usage
    exit 2
fi

readonly device_id=$1
readonly csr_path=${2:-firezone-device.csr}

if [[ ! $device_id =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
    echo "DEVICE_ID must be a UUID assigned by the enrollment administrator." >&2
    exit 2
fi

if [[ -e $csr_path ]]; then
    echo "Refusing to overwrite $csr_path" >&2
    exit 1
fi

if [[ $EUID -ne 0 && $store == "$default_store" && $state_dir == "$default_state_dir" ]]; then
    echo "Run this script with sudo." >&2
    exit 1
fi

for required_command in dpkg openssl tpm2_ptool; do
    if ! command -v "$required_command" >/dev/null; then
        echo "Missing $required_command. Install the Ubuntu packages listed in the Firezone README." >&2
        exit 1
    fi
done

module_path=$(dpkg -L libtpm2-pkcs11-1 2>/dev/null | awk '/\/libtpm2_pkcs11\.so$/ { print; exit }')
if [[ -z $module_path || ! -r $module_path ]]; then
    echo "Could not find libtpm2_pkcs11.so. Install libtpm2-pkcs11-1." >&2
    exit 1
fi
readonly module_path

umask 077
install -d -m 0700 "$store" "$state_dir"

if [[ ! -f $store/tpm2_pkcs11.sqlite3 ]]; then
    user_pin=$(openssl rand -hex 16)
    so_pin=$(openssl rand -hex 16)
    printf '%s' "$user_pin" >"$pin_file"
    printf '%s' "$so_pin" >"$so_pin_file"
    chmod 0600 "$pin_file" "$so_pin_file"

    init_output=$(tpm2_ptool init \
        --path "$store" \
        --transient-parent tpm2-tools-ecc-default)
    primary_id=$(awk '$1 == "id:" { print $2; exit }' <<<"$init_output")
    if [[ -z $primary_id ]]; then
        echo "Could not determine the TPM2-PKCS11 primary ID." >&2
        exit 1
    fi
    printf '%s\n' "$primary_id" >"$primary_id_file"
fi

for state_file in "$pin_file" "$so_pin_file" "$primary_id_file"; do
    if [[ ! -r $state_file ]]; then
        echo "Missing TPM2-PKCS11 state file: $state_file" >&2
        exit 1
    fi
done

user_pin=$(<"$pin_file")
so_pin=$(<"$so_pin_file")
primary_id=$(<"$primary_id_file")

token_output=$(tpm2_ptool listtokens --path "$store" --pid "$primary_id")
if ! grep -Fq "label: $token_label" <<<"$token_output"; then
    tpm2_ptool addtoken \
        --path "$store" \
        --pid "$primary_id" \
        --label "$token_label" \
        --sopin "$so_pin" \
        --userpin "$user_pin"
fi

object_output=$(tpm2_ptool listobjects --path "$store" --label "$token_label")
if ! grep -Fq "CKA_LABEL: $key_label" <<<"$object_output"; then
    tpm2_ptool addkey \
        --path "$store" \
        --label "$token_label" \
        --key-label "$key_label" \
        --id "$key_id" \
        --algorithm ecc256 \
        --userpin "$user_pin"
fi

readonly key_uri="pkcs11:token=$token_label;object=$key_label;type=private?pin-source=file:$pin_file"

PKCS11_MODULE_PATH="$module_path" \
    TPM2_PKCS11_STORE="$store" \
    openssl req \
    -new \
    -batch \
    -sha256 \
    -engine pkcs11 \
    -keyform engine \
    -key "$key_uri" \
    -subj "/CN=dev.firezone.device-trust" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=clientAuth" \
    -addext "subjectAltName=URI:$device_id" \
    -out "$csr_path"

openssl req -in "$csr_path" -noout -verify

if [[ -n ${SUDO_UID:-} && -n ${SUDO_GID:-} ]]; then
    chown "$SUDO_UID:$SUDO_GID" "$csr_path"
fi

echo "CSR written to $csr_path"
