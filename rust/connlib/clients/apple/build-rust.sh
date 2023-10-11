#!/bin/bash

##################################################
# We call this from an Xcode run script.
##################################################

set -e

if [[ $1 == "clean" ]]; then
  echo "Skipping build during 'clean'"
  exit 0
fi

if [[ -z "$PLATFORM_NAME" ]]; then
  echo "PLATFORM_NAME is not set"
  exit 1
fi

# Use the lld linker from llvm. Fixes issues with building Rust with Xcode 15's
# for aarch64-apple-ios.
#
# lld is also faster than the default macOS LD64 linker.
#
# `brew` is not in our PATH in this script, so adjust PATH temporarily just for
# this command to avoid polluting the build env.
# We use llvm@15 because that's what's installed on our CI.
lld_path="$(PATH=/opt/homebrew/bin:/usr/local/bin:$PATH brew --prefix llvm@15):/usr/bin/ld64.lld"
if [[ $? -ne 0 ]]; then
  echo "Could not find llvm@15. Maybe try 'brew install llvm@15' or update this script to use a newer llvm if available."
  exit 1
fi

base_dir=$(xcrun --sdk $PLATFORM_NAME --show-sdk-path)

export PATH="$HOME/.cargo/bin:$PATH"
export INCLUDE_PATH="$base_dir/usr/include:${INCLUDE_PATH:-}"
export LIBRARY_PATH="$base_dir/usr/lib:${LIBRARY_PATH:-}"
export RUSTFLAGS="-C link-arg=-F$base_dir/System/Library/Frameworks -C link-arg=-fuse-ld=$lld_path"
export CFLAGS="-L ${LIBRARY_PATH} -I ${INCLUDE_PATH}"

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
  CARGO_TARGET_DIR=$CONNLIB_TARGET_DIR
  set +x
fi

set -x
cargo build --verbose $TARGETS $CONFIGURATION_ARGS
set +x
