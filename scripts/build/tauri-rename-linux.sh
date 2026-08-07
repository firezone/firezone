#!/usr/bin/env bash
#
# Runs from `rust/gui-client` or `rust/tauri-client`

set -euox pipefail

# For debugging
ls "$TARGET_DIR/release" "$TARGET_DIR/release/bundle/deb" "$TARGET_DIR/release/bundle/rpm"

# In release mode the name comes from tauri.conf.json
# Using a glob for the source, there will only be one deb anyway
cp $TARGET_DIR/release/bundle/deb/firezone-client-gui*.deb "$BINARY_DEST_PATH.deb"
cp $TARGET_DIR/release/bundle/rpm/firezone-client-gui*.rpm "$BINARY_DEST_PATH.rpm"

# Tauri has no counterpart to the RPM release tag for `.deb`s: both bundlers
# read the same package version. Stamp the revision into the control file
# afterwards so that, like the `.rpm`, every build gets a version of its own and
# stops overwriting its predecessor in the preview pool.
#
# Only `control` changes; `data.tar` is rebuilt from what `dpkg-deb -R` unpacked.
# Tauri writes that tree with uid/gid 0, which `--root-owner-group` reproduces
# without needing `fakeroot`.
if [[ -n "${DEB_REVISION:-}" ]]; then
    UNPACKED="$(mktemp -d)"

    dpkg-deb -R "$BINARY_DEST_PATH.deb" "$UNPACKED"
    sed -i "s/^Version: .*/&-${DEB_REVISION}/" "$UNPACKED/DEBIAN/control"
    dpkg-deb --build --root-owner-group "$UNPACKED" "$BINARY_DEST_PATH.deb"

    rm -rf "$UNPACKED"
fi

function make_hash() {
    sha256sum "$1" >"$1.sha256sum.txt"
}

make_hash "$BINARY_DEST_PATH.deb"
make_hash "$BINARY_DEST_PATH.rpm"
