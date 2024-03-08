#!/bin/bash

##################################################
# We call this from an Xcode run script.
##################################################

set -e

# Sanitize the environment to prevent Xcode's shenanigans from leaking
# into our highly evolved Rust-based build system.
for var in $(env | awk -F= '{print $1}'); do
    if [[ "$var" != "HOME" ]] &&
        [[ "$var" != "USER" ]] &&
        [[ "$var" != "LOGNAME" ]] &&
        [[ "$var" != "TERM" ]] &&
        [[ "$var" != "PWD" ]] &&
        [[ "$var" != "SHELL" ]] &&
        [[ "$var" != "TMPDIR" ]] &&
        [[ "$var" != "XPC_FLAGS" ]] &&
        [[ "$var" != "XPC_SERVICE_NAME" ]] &&
        [[ "$var" != "PLATFORM_NAME" ]] &&
        [[ "$var" != "CONFIGURATION" ]] &&
        [[ "$var" != "NATIVE_ARCH" ]] &&
        [[ "$var" != "ONLY_ACTIVE_ARCH" ]] &&
        [[ "$var" != "ARCHS" ]] &&
        [[ "$var" != "SDKROOT" ]] &&
        [[ "$var" != "OBJROOT" ]] &&
        [[ "$var" != "SYMROOT" ]] &&
        [[ "$var" != "SRCROOT" ]] &&
        [[ "$var" != "TARGETED_DEVICE_FAMILY" ]] &&
        [[ "$var" != "RUSTC_WRAPPER" ]] &&
        [[ "$var" != "RUST_TOOLCHAIN" ]] &&
        [[ "$var" != "SCCACHE_GCS_BUCKET" ]] &&
        [[ "$var" != "SCCACHE_GCS_RW_MODE" ]] &&
        [[ "$var" != "GOOGLE_CLOUD_PROJECT" ]] &&
        [[ "$var" != "GCP_PROJECT" ]] &&
        [[ "$var" != "GCLOUD_PROJECT" ]] &&
        [[ "$var" != "CLOUDSDK_PROJECT" ]] &&
        [[ "$var" != "CLOUDSDK_CORE_PROJECT" ]] &&
        [[ "$var" != "GOOGLE_GHA_CREDS_PATH" ]] &&
        [[ "$var" != "GOOGLE_APPLICATION_CREDENTIALS" ]] &&
        [[ "$var" != "CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE" ]] &&
        [[ "$var" != "ACTIONS_CACHE_URL" ]] &&
        [[ "$var" != "ACTIONS_RUNTIME_TOKEN" ]] &&
        [[ "$var" != "CARGO_INCREMENTAL" ]] &&
        [[ "$var" != "CARGO_TERM_COLOR" ]] &&
        [[ "$var" != "CONNLIB_TARGET_DIR" ]]; then
        unset $var
    fi
done

# Use pristine path; the PATH from Xcode is polluted with stuff we don't want which can
# confuse rustc.
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:$HOME/.cargo/bin:/run/current-system/sw/bin/"

if [[ $1 == "clean" ]]; then
    echo "Skipping build during 'clean'"
    exit 0
fi

if [[ -z "$PLATFORM_NAME" ]]; then
    echo "PLATFORM_NAME is not set"
    exit 1
fi

export INCLUDE_PATH="$SDK_ROOT/usr/include"
export LIBRARY_PATH="$SDK_ROOT/usr/lib"

TARGETS=""
if [[ "$PLATFORM_NAME" = "macosx" ]]; then
    if [[ $CONFIGURATION == "Release" ]] || [[ -z "$NATIVE_ARCH" ]]; then
        TARGETS="--target aarch64-apple-darwin --target x86_64-apple-darwin"
    else
        if [[ $NATIVE_ARCH == "arm64" ]]; then
            TARGETS="--target aarch64-apple-darwin"
        else
            if [[ $NATIVE_ARCH == "x86_64" ]]; then
                TARGETS="--target x86_64-apple-darwin"
            else
                echo "Unsupported native arch for $PLATFORM_NAME: $NATIVE_ARCH"
            fi
        fi
    fi
else
    if [[ "$PLATFORM_NAME" = "iphoneos" ]]; then
        TARGETS="--target aarch64-apple-ios"
    else
        echo "Unsupported platform: $PLATFORM_NAME"
        exit 1
    fi
fi

MESSAGE="Building Connlib"

if [[ $CONFIGURATION == "Release" ]]; then
    echo "${MESSAGE} for Release"
    CONFIGURATION_ARGS="--release"
else
    echo "${MESSAGE} for Debug"
fi

if [[ -n "$CONNLIB_TARGET_DIR" ]]; then
    set -x
    export CARGO_TARGET_DIR=$CONNLIB_TARGET_DIR
    set +x
fi

set -x
cargo build --verbose $TARGETS $CONFIGURATION_ARGS
set +x
