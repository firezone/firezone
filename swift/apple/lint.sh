#!/bin/bash

##################################################
# We call this from an Xcode run script.
##################################################

set -e

if [[ "$(uname -m)" == arm64 ]]; then
    export PATH="/opt/homebrew/bin:$PATH"
fi

if which swift-format >/dev/null; then
    find . -name "*.swift" -not -path "./FirezoneNetworkExtension/Connlib/Generated/*" -exec xargs swift-format lint --strict \;
else
    echo "warning: swift-format not installed, install with $(brew install swift-format)"
fi
