#!/bin/bash

##################################################
# We call this from an Xcode run script.
##################################################

set -ex

if [[ -z "$PROJECT_DIR" ]]; then
  echo "Must provide PROJECT_DIR environment variable set to the Xcode project directory." 1>&2
  exit 1
fi

cd $PROJECT_DIR

# Default PLATFORM_NAME to macosx if not set.
: "${PLATFORM_NAME:=macosx}"


export PATH="$HOME/.cargo/bin:$PATH"

base_dir=$(xcrun --sdk $PLATFORM_NAME --show-sdk-path)

# See https://github.com/briansmith/ring/issues/1332
export LIBRARY_PATH="${base_dir}/usr/lib"
export INCLUDE_PATH="${base_dir}/usr/include"
export CFLAGS="-L ${LIBRARY_PATH} -I ${INCLUDE_PATH}"
export RUSTFLAGS="-C link-arg=-F$base_dir/System/Library/Frameworks"

TARGETS=""
if [[ "$PLATFORM_NAME" = "macosx" ]]; then
  TARGETS="aarch64-apple-darwin,x86_64-apple-darwin"
else
  if [[ "$PLATFORM_NAME" = "iphonesimulator" ]]; then
    TARGETS="aarch64-apple-ios-sim,x86_64-apple-ios"
  else
    if [[ "$PLATFORM_NAME" = "iphoneos" ]]; then
      TARGETS="aarch64-apple-ios"
    else
      echo "Unsupported platform: $PLATFORM_NAME"
      exit 1
    fi
  fi
fi

# if [ $ENABLE_PREVIEWS == "NO" ]; then

  if [[ $CONFIGURATION == "Release" ]]; then
      echo "BUILDING FOR RELEASE ($TARGETS)"

      cargo lipo --release --manifest-path ./Cargo.toml  --targets $TARGETS
  else
      echo "BUILDING FOR DEBUG ($TARGETS)"

      cargo lipo --manifest-path ./Cargo.toml  --targets $TARGETS
  fi

# else
#   echo "Skipping the script because of preview mode"
# fi
