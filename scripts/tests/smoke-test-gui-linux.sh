#!/usr/bin/env bash

set -euo pipefail

BUNDLE_ID="dev.firezone.client"
DUMP_PATH="$BUNDLE_ID/data/logs/last_crash.dmp"
export FIREZONE_DISABLE_SYSTRAY=true
PACKAGE=firezone-windows-client
export RUST_LOG=firezone_windows_client=debug,warn

# Run the smoke test normally
xvfb-run --auto-servernum cargo run -p "$PACKAGE" -- smoke-test

# Delete the crash file if present
rm -f "$DUMP_PATH"

# Fail if it returns success, this is supposed to crash
xvfb-run --auto-servernum cargo run -p "$PACKAGE" -- --crash && exit 1

# Fail if the crash file wasn't written
stat "$DUMP_PATH"
rm "$DUMP_PATH"

# I'm not sure if the last command is handled specially, so explicitly exit with 0
exit 0
