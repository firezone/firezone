#!/usr/bin/env bash

set -euo pipefail

rm target/debian/*.deb

pushd .. > /dev/null
cargo build --release --bin firezone-client-ipc
popd > /dev/null

cargo deb
mv target/debian/*.deb target/debian/firezone-client-gui.deb
