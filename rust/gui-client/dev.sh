#!/bin/sh

# The Windows client obviously doesn't build for *nix, but this
# script is helpful for doing UI work on those platforms for the
# Windows client.
set -e

# Fixes exiting with Ctrl-C
stop() {
    kill "$(jobs -p)"
}
trap stop INT TERM

# Start Tauri hot-reloading: Not applicable for Windows
tauri dev
