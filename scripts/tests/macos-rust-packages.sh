#!/usr/bin/env bash
# Usage: For CI scripts to source

set -euo pipefail

export FIREZONE_PACKAGES="-p connlib-client-apple -p connlib-client-shared -p firezone-tunnel -p snownet"
