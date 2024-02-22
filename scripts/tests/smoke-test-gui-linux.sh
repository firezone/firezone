#!/usr/bin/env bash

set -euo pipefail

BUNDLE_ID="dev.firezone.client"
DUMP_PATH="$HOME/.cache/$BUNDLE_ID/data/logs/last_crash.dmp"
export FIREZONE_DISABLE_SYSTRAY=true
PACKAGE=firezone-gui-client
export RUST_LOG=firezone_gui_client=debug,warn
export WEBKIT_DISABLE_COMPOSITING_MODE=1

# Make sure the files the client produces don't exist yet
stat "$HOME/.config/$BUNDLE_ID" && exit 1
stat "$HOME/.cache/$BUNDLE_ID" && exit 1

# Run the smoke test normally
xvfb-run --auto-servernum cargo run -p "$PACKAGE" -- smoke-test

# Make sure the client wrote its files in the right paths
stat "$HOME/.cache/$BUNDLE_ID/data/logs/connlib*log"
stat "$HOME/.config/$BUNDLE_ID/config/advanced_settings.json"
stat "$HOME/.config/$BUNDLE_ID/config/device_id.json"

# Delete the crash file if present
rm -f "$DUMP_PATH"

# Fail if it returns success, this is supposed to crash
xvfb-run --auto-servernum cargo run -p "$PACKAGE" -- --crash && exit 1

# Fail if the crash file wasn't written
stat "$DUMP_PATH"
rm "$DUMP_PATH"

# I'm not sure if the last command is handled specially, so explicitly exit with 0
exit 0
