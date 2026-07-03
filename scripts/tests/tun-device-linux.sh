#!/usr/bin/env bash

# Boots the headless Client and checks that the TUN device is created
# with the offload features that we enable programmatically.

source "./scripts/tests/lib.sh"

BINARY_NAME=firezone-headless-client
DEVICE="tun-firezone"

command -v ethtool >/dev/null || sudo apt-get install -y ethtool

cd rust || exit 1
cargo build -p "$BINARY_NAME"
cd ..

sudo cp "rust/target/debug/$BINARY_NAME" "/usr/bin/$BINARY_NAME"

# `create-tun-device` is only available in debug builds.
sudo RUST_LOG=debug "$BINARY_NAME" create-tun-device &
CLIENT_PID=$!

for _ in $(seq 1 30); do
    ip link show "$DEVICE" && break
    sleep 1
done

# `rx-udp-gro-forwarding` is off by default, so this proves we enabled it.
sudo ethtool --show-features "$DEVICE" | grep "rx-udp-gro-forwarding: on"

sudo kill "$CLIENT_PID"

exit 0
