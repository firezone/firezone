#!/usr/bin/env bash
# Figured out from this: <https://github.com/hwchen/keyring-rs/blob/master/linux-test.sh>

set -euo pipefail

echo -n "test" | gnome-keyring-daemon --unlock --replace
cargo test -p firezone-windows-client
