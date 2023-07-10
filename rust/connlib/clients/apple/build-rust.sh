#!/bin/bash

##################################################
# We call this from an Xcode run script.
##################################################

set -e

# Default PLATFORM_NAME to macosx if not set.
: "${PLATFORM_NAME:=macosx}"

export PATH="$HOME/.cargo/bin:$PATH"

base_dir=$(xcrun --sdk $PLATFORM_NAME --show-sdk-path)

# See https://github.com/briansmith/ring/issues/1332
export LIBRARY_PATH="${base_dir}/usr/lib"
export INCLUDE_PATH="${base_dir}/usr/include"
# `-Qunused-arguments` stops clang from failing while building *ring*
# (but the library search path is still necessary when building the framework!)
export CFLAGS="-L ${LIBRARY_PATH} -I ${INCLUDE_PATH} -Qunused-arguments"
export RUSTFLAGS="-C link-arg=-F$base_dir/System/Library/Frameworks"

TARGETS=()
if [[ "$PLATFORM_NAME" = "macosx" ]]; then
    TARGETS=("aarch64-apple-darwin" "x86_64-apple-darwin")
else
  if [[ "$PLATFORM_NAME" = "iphonesimulator" ]]; then
    TARGETS=("aarch64-apple-ios-sim" "x86_64-apple-ios")
  else
    if [[ "$PLATFORM_NAME" = "iphoneos" ]]; then
      TARGETS="aarch64-apple-ios"
    else
      echo "Unsupported platform: $PLATFORM_NAME"
      exit 1
    fi
  fi
fi

MESSAGE="Building Connlib"

if [[ -n "$CONNLIB_MOCK" ]]; then
  MESSAGE="${MESSAGE} (mock)"
  FEATURE_ARGS="--features mock"
fi

if [[ $CONFIGURATION == "Release" ]]; then
  echo "${MESSAGE} for Release"
  CONFIGURATION_ARGS="--release"
else
  echo "${MESSAGE} for Debug"
fi

for target in "${TARGETS[@]}"
do
  cargo build --target $target $FEATURE_ARGS $CONFIGURATION_ARGS
done
