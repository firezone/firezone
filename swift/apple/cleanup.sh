#!/bin/bash

set -e

ARG=$1

if [[ -z "$ARG" ]]; then
  ARG="swift"
fi

if [[ $ARG == "all" ]] || [[ $ARG == "swift" ]] || [[ $ARG == "rust" ]]; then
  echo "Cleaning up $ARG build artifacts";
else
  echo "Usage: $0 [ all | swift | rust ]"
  echo "       (Default: swift)"
fi

if [[ $ARG == "swift" ]] || [[ $ARG == "all" ]]; then
  set -x
  xcodebuild clean
  rm -rf ./FirezoneNetworkExtension/Connlib
  set +x
fi

if [[ $ARG == "rust" ]] || [[ $ARG == "all" ]]; then
  set -x
  cd ../../rust/apple-client-ffi && cargo clean
  cd Sources/Connlib/Generated && git clean -df
  set +x
fi
