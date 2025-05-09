#!/usr/bin/env bash
# These steps must be synchronized with `gui-smoke-test` in `_rust.yml`.

set -euo pipefail

# Dir where all the bundles are built
BUNDLES_DIR=../target/release/bundle/deb

# Prep the RPM container
docker build . -f ../Dockerfile-rpm -t rpmbuild

# Copy frontend dependencies
cp node_modules/flowbite/dist/flowbite.min.js src/

# Compile CSS
pnpm tailwindcss -i src/input.css -o src/output.css

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

# Delete the deb that Tauri built. We're going to modify and rebuild it.
rm "$BUNDLES_DIR"/*.deb

# There should be only one directory in `bundle/deb`, we need to modify
# files inside that dir
INTERMEDIATE_DIR=$(ls -d "$BUNDLES_DIR"/*/)

# Delete the archives, we will re-create them.
rm "$INTERMEDIATE_DIR"/*.tar.gz

# The directory layout of `$BUNDLES_DIR` now looks like this:
#  └── firezone-client-gui_1.x.y_$arch
#     ├── control
#     │   ├── control
#     │   └── md5sums
#     ├── data
#     │   └── usr
#     │       ├── bin
#     │       │   └── firezone-client-gui
#     │       ├── lib
#     │       │   ├── systemd
#     │       │   │   └── system
#     │       │   │       └── firezone-client-ipc.service
#     │       │   └── sysusers.d
#     │       │       └── firezone-client-ipc.conf
#     │       └── share
#     │           ├── applications
#     │           │   └── firezone-client-gui.desktop
#     │           └── icons
#     │               └── ...
#     └── debian-binary

# Add the scripts
cp src-tauri/deb_files/postinst src-tauri/deb_files/prerm "$INTERMEDIATE_DIR/control/"

# Add the IPC service
cp ../target/release/firezone-client-ipc "$INTERMEDIATE_DIR/data/usr/bin/"

pushd "$INTERMEDIATE_DIR"

# Rebuild the control tarball
tar -C "control" -czf "control.tar.gz" control md5sums postinst prerm

# Rebuild the data tarball
tar -C "data" -czf "data.tar.gz" usr

# Rebuild the deb package, and give it a predictable name that
# `tauri-rename-linux.sh` can fix
ar rcs "../firezone-client-gui.deb" debian-binary control.tar.gz data.tar.gz
popd
