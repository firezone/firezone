#!/usr/bin/env bash

set -e

# See https://docs.github.com/en/actions/use-cases-and-examples/deploying/installing-an-apple-certificate-on-macos-runners-for-xcode-development
function setup_runner() {
    local app_profile="$1"
    local app_profile_file="$2"
    local ne_profile="$3"
    local ne_profile_file="$4"

    # Use the latest version of Xcode - matches what we typically use for development
    sudo xcode-select --switch "$(ls -d /Applications/Xcode*.app | sort -V | tail -n 1)"

    profiles_path="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
    keychain_pass=$(openssl rand -base64 32)
    keychain_path="$(mktemp -d)/app-signing.keychain-db"

    # Install provisioning profiles
    mkdir -p "$profiles_path"
    base64_decode "$app_profile" "$profiles_path/$app_profile_file"
    base64_decode "$ne_profile" "$profiles_path/$ne_profile_file"

    # Create a keychain to use for signing
    security create-keychain -p "$keychain_pass" "$keychain_path"

    # Set it as the default keychain so Xcode can find the signing certs
    security default-keychain -s "$keychain_path"

    # Ensure it stays unlocked during the build
    security set-keychain-settings -lut 21600 "$keychain_path"

    # Unlock the keychain for use
    security unlock-keychain -p "$keychain_pass" "$keychain_path"

    # Install signing certs
    install_cert \
        "$BUILD_CERT" \
        "$BUILD_CERT_PASS" \
        "$keychain_pass" \
        "$keychain_path"
    install_cert \
        "$INSTALLER_CERT" \
        "$INSTALLER_CERT_PASS" \
        "$keychain_pass" \
        "$keychain_path"
    install_cert \
        "$STANDALONE_BUILD_CERT" \
        "$STANDALONE_BUILD_CERT_PASS" \
        "$keychain_pass" \
        "$keychain_path"
    install_cert \
        "$STANDALONE_INSTALLER_CERT" \
        "$STANDALONE_INSTALLER_CERT_PASS" \
        "$keychain_pass" \
        "$keychain_path"
}

function extract_uuid() {
    local b64_profile="$1"

    echo "$b64_profile" | base64 --decode | security cms -D | plutil -extract UUID raw -o - -
}

function base64_decode() {
    local input_stdin="$1"
    local output_path="$2"

    echo -n "$input_stdin" | base64 --decode -o "$output_path"
}

function install_cert() {
    local cert_path
    local cert="$1"
    local pass="$2"
    local keychain_pass="$3"
    local keychain_path="$4"

    cert_path="$(mktemp -d)/cert.p12"

    base64_decode "$cert" "$cert_path"

    # Import cert into keychain
    security import "$cert_path" \
        -P "$pass" \
        -A \
        -t cert \
        -f pkcs12 \
        -k "$keychain_path"

    # Prevent the keychain from asking for password to access the cert
    security set-key-partition-list \
        -S apple-tool:,apple: \
        -k "$keychain_pass" \
        "$keychain_path"

    # Clean up
    rm "$cert_path"
}
