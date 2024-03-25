#!/bin/bash

##################################################
# We call this from an Xcode run script.
##################################################

set -e

if [[ "$(uname -m)" == arm64 ]]; then
    export PATH="/opt/homebrew/bin:$PATH"
fi

swiftlint lint --strict
