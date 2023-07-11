#!/bin/bash

##################################################
# We call this from an Xcode run script.
##################################################

set -e

if [[ $1 == "clean" ]]; then
  echo "Skipping build during 'clean'"
  exit 0
fi

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
    if [[ $CONFIGURATION == "Release" ]] || [[ -z "$NATIVE_ARCH" ]]; then
      TARGETS=("aarch64-apple-darwin" "x86_64-apple-darwin")
    else
      if [[ $NATIVE_ARCH == "arm64" ]]; then
        TARGETS=("aarch64-apple-darwin")
      else
        if [[ $NATIVE_ARCH == "x86_64" ]]; then
          TARGETS=("x86_64-apple-darwin")
	else
          echo "Unsupported native arch for $PLATFORM_NAME: $NATIVE_ARCH"
        fi
      fi
    fi
else
  if [[ "$PLATFORM_NAME" = "iphonesimulator" ]]; then
    if [[ $CONFIGURATION == "Release" ]] || [[ -z "$NATIVE_ARCH" ]]; then
      TARGETS=("aarch64-apple-ios-sim" "x86_64-apple-ios")
    else
      if [[ $NATIVE_ARCH == "arm64" ]]; then
        TARGETS=("aarch64-apple-ios-sim")
      else
        if [[ $NATIVE_ARCH == "x86_64" ]]; then
          TARGETS=("x86_64-apple-ios")
	else
          echo "Unsupported native arch for $PLATFORM_NAME: $NATIVE_ARCH"
        fi
      fi
    fi
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

if [[ -n "$CONNLIB_TARGET_DIR" ]]; then
  CONNLIB_TARGET_ARGS="--target-dir $CONNLIB_TARGET_DIR"
fi

for target in "${TARGETS[@]}"
do
  set -x
  cargo build --target $target $CONNLIB_TARGET_ARGS $FEATURE_ARGS $CONFIGURATION_ARGS
  set +x
done
