#!/usr/bin/env bash

set -e

# See https://docs.github.com/en/actions/use-cases-and-examples/deploying/installing-an-apple-certificate-on-macos-runners-for-xcode-development
function setup_runner() {
    local app_profile="$1"
    local app_profile_path="$2"
    local ne_profile="$3"
    local ne_profile_path="$4"
    profiles_path="$HOME/Library/MobileDevice/Provisioning Profiles"
    keychain_pass=$(openssl rand -base64 32)
    keychain_path="$(mktemp -d)/app-signing.keychain-db"

    # Select Xcode specified by the workflow
    sudo xcode-select -s "/Applications/Xcode_$XCODE_VERSION.app"

    # Install provisioning profiles
    mkdir -p "$profiles_path"
    install_provisioning_profile \
        "$profiles_path" \
        "$app_profile" \
        "$app_profile_path"
    install_provisioning_profile \
        "$profiles_path" \
        "$ne_profile" \
        "$ne_profile_path"

    # Create a keychain to use for signing
    security create-keychain -p "$keychain_pass" "$keychain_path"
    security default-keychain -s "$keychain_path"
    security set-keychain-settings -lut 21600 "$keychain_path"
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
}

function install_provisioning_profile() {
    local profiles_path="$1"
    local profile="$2"
    local profile_file="$3"

    echo -n "$profile" | base64 --decode -o "$profiles_path/$profile_file"
}

function install_cert() {
    local cert_path
    local cert="$1"
    local pass="$2"
    local keychain_pass="$3"
    local keychain_path="$4"

    cert_path="$(mktemp -d)/cert.p12"

    echo -n "$cert" | base64 --decode -o "$cert_path"
    security import "$cert_path" \
        -P "$pass" \
        -A \
        -t cert \
        -f pkcs12 \
        -k "$keychain_path"
    security set-key-partition-list \
        -S apple-tool:,apple: \
        -k "$keychain_pass" \
        "$keychain_path"

    rm "$cert_path"
}

function insert_build_timestamp() {
    local project_file="$1"

    seconds_since_epoch=$(date +%s)
    sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]/CURRENT_PROJECT_VERSION = $seconds_since_epoch/" \
        "$project_file"
}
