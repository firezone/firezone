#!/bin/bash

##################################################
# We call this from an Xcode run script.
##################################################

set -ex

DEST=./FirezoneNetworkExtension/Connlib
if [[ -n "$CONNLIB_SOURCE_DIR" ]]; then
    rm -rf ${DEST}
    find ${CONNLIB_SOURCE_DIR}/Sources/Connlib
    cp -r ${CONNLIB_SOURCE_DIR}/Sources/Connlib ${DEST}
else
    echo "CONNLIB_SOURCE_DIR is not set. Is this being invoked from Xcode?"
fi
