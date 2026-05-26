#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}/.."

# spotlessCheck only touches .kt source files; it does not pull the connlib cargo
# build, so it needs no ABI narrowing.
echo "Checking Kotlin code style..."
mise exec -- ./gradlew spotlessCheck

# Android Lint pulls a connlib cargo build (the `main` source set includes the
# uniffi-generated bindings). Lint runs per-variant, never per-ABI, and the bindings
# are identical across ABIs, so one ABI is enough. Narrow to the host ABI to avoid the
# otherwise-unscoped 4-ABI build and to reuse `mise run build`'s cargo artifacts.
echo "Running Android Lint..."
case "$(uname -m)" in
x86_64 | amd64) mise exec -- ./gradlew lint "-Pandroid.injected.build.abi=x86_64" ;;
arm64 | aarch64) mise exec -- ./gradlew lint "-Pandroid.injected.build.abi=arm64-v8a" ;;
*)
    echo "Unsupported host arch $(uname -m); linting against all ABIs." >&2
    mise exec -- ./gradlew lint
    ;;
esac
