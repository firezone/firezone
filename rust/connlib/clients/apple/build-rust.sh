#!/bin/bash

##################################################
# We call this from an Xcode run script.
##################################################

set -e

# Sanitize the environment to prevent Xcode's shenanigans from leaking
# into our highly evolved Rust-based build system.
for var in $(env | awk -F= '{print $1}'); do
  # standard vars
  if [[ "$var" != "PATH" ]] \
  && [[ "$var" != "HOME" ]] \
  && [[ "$var" != "USER" ]] \
  && [[ "$var" != "LOGNAME" ]] \
  && [[ "$var" != "TERM" ]] \
  && [[ "$var" != "PWD" ]] \
  && [[ "$var" != "SHELL" ]] \
  && [[ "$var" != "SHELL" ]] \
  && [[ "$var" != "TMPDIR" ]] \
  && [[ "$var" != "XPC_FLAGS" ]] \
  && [[ "$var" != "XPC_SERVICE_NAME" ]] \
  # Needed vars from Xcode
  \ && [[ "$var" != "PLATFORM_NAME" ]] \
  && [[ "$var" != "CONFIGURATION" ]] \
  && [[ "$var" != "NATIVE_ARCH" ]] \
  && [[ "$var" != "CONNLIB_TARGET_DIR" ]]; then
  unset $var
  fi
done

if [[ $1 == "clean" ]]; then
  echo "Skipping build during 'clean'"
  exit 0
fi

if [[ -z "$PLATFORM_NAME" ]]; then
  echo "PLATFORM_NAME is not set"
  exit 1
fi

base_dir=$(xcrun --sdk $PLATFORM_NAME --show-sdk-path)
export PATH="$HOME/.cargo/bin:$PATH"
export INCLUDE_PATH="$base_dir/usr/include"
export LIBRARY_PATH="$base_dir/usr/lib"

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
