#!/usr/bin/env bash
# This script must run from an elevated shell so that Firezone won't try to elevate

set -euo pipefail

BUNDLE_ID="dev.firezone.client"
DUMP_PATH="$LOCALAPPDATA/$BUNDLE_ID/data/logs/last_crash.dmp"
PACKAGE=firezone-gui-client

# Fail if the environment doesn't have `C:\ProgramData` known folder
${ProgramData:?}

# Make sure the files we want to check don't exist on the system yet
stat "$LOCALAPPDATA/$BUNDLE_ID" && exit 1
stat "$ProgramData/$BUNDLE_ID" && exit 1

# Run the smoke test normally
cargo run -p "$PACKAGE" -- smoke-test

# Make sure the files were written in the right paths
stat "$LOCALAPPDATA/$BUNDLE_ID/config/advanced_settings.json"
stat "$LOCALAPPDATA/$BUNDLE_ID/data/logs/connlib*log"
stat "$LOCALAPPDATA/$BUNDLE_ID/data/wintun.dll"
stat "$ProgramData/$BUNDLE_ID/config/device_id.json"

# Delete the crash file if present
rm -f "$DUMP_PATH"

# Fail if it returns success, this is supposed to crash
cargo run -p "$PACKAGE" -- --crash && exit 1

# Fail if the crash file wasn't written
stat "$DUMP_PATH"
rm "$DUMP_PATH"

# I'm not sure if the last command is handled specially, so explicitly exit with 0
exit 0
