#!/usr/bin/env bash

set -euo pipefail

# Delete old deb packages so the `mv` glob will work later on
rm -f target/debian/*.deb

sudo apt-get install libgtk-3-dev libxdo-dev
cargo install cargo-deb@2.7.0

cargo deb
mv target/debian/*.deb target/debian/firezone-client-gui.deb
ls target/debian
