#!/usr/bin/env bash
# Usage: For CI scripts to source

set -euo pipefail

export FIREZONE_PACKAGES="-p connlib-client-shared -p firezone-client-tunnel -p firezone-gui-client -p firezone-tunnel -p snownet"
