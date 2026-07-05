#!/usr/bin/env bash

# Boots the headless Client and checks that the TUN device is created
# with the NAPI tuning that we apply programmatically.

source "./scripts/tests/lib.sh"

BINARY_NAME=firezone-headless-client
DEVICE="tun-firezone"

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

# NAPI polling is not threaded by default, so this proves we enabled it.
test "$(cat /sys/class/net/$DEVICE/threaded)" = "1"

sudo kill "$CLIENT_PID"

exit 0
