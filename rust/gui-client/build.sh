#!/usr/bin/env bash
# These steps must be synchronized with `gui-smoke-test` in `_rust.yml`.

set -euo pipefail

# Dir where all the bundles are built
BUNDLES_DIR=../target/release/bundle/deb

# Prep the RPM container
docker build . -f ../Dockerfile-rpm -t rpmbuild

# Bundle all web assets
pnpm vite build

# Get rid of any existing debs, since we need to discover the path later
rm -rf "$BUNDLES_DIR"

# Compile Rust and bundle
pnpm tauri build

# Build the RPM file
docker run \
--rm \
-v $PWD/..:/root/rpmbuild \
-v /usr/lib:/root/libs \
-w /root/rpmbuild/gui-client \
rpmbuild \
rpmbuild \
-bb src-tauri/rpm_files/firezone-gui-client.spec \
--define "_topdir /root/rpmbuild/gui-client/rpmbuild"

# Un-mess-up the permissions Docker gave it
sudo chown --recursive $USER:$USER rpmbuild

# Give it a predictable name
cp rpmbuild/RPMS/*/firezone-client-gui-*rpm "firezone-client-gui.rpm"
