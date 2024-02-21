#!/bin/bash

##################################################
# We call this from an Xcode run script.
##################################################

set -e

if [[ $1 == "clean" ]]; then
    echo "Skipping copy during 'clean'"
    exit 0
fi

DEST=./FirezoneNetworkExtension/Connlib
if [[ -n "$CONNLIB_SOURCE_DIR" ]]; then
    set -x
    rm -rf $DEST
    find "$CONNLIB_SOURCE_DIR"/Sources/Connlib
    cp -r "$CONNLIB_SOURCE_DIR"/Sources/Connlib $DEST
    set +x
else
    echo "CONNLIB_SOURCE_DIR is not set. Is this being invoked from Xcode?"
fi
