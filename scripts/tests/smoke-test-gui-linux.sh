#!/usr/bin/env bash

set -euo pipefail

BUNDLE_ID="dev.firezone.client"
DUMP_PATH="$HOME/.cache/$BUNDLE_ID/data/logs/last_crash.dmp"
export FIREZONE_DISABLE_SYSTRAY=true
PACKAGE=firezone-gui-client
export RUST_LOG=firezone_gui_client=debug,warn
export WEBKIT_DISABLE_COMPOSITING_MODE=1

function smoke_test() {
    # Make sure the files we want to check don't exist on the system yet
    stat "$HOME/.cache/$BUNDLE_ID/data/logs" && exit 1
    stat "$HOME/.config/$BUNDLE_ID/config/advanced_settings.json" && exit 1
    stat "$HOME/.config/$BUNDLE_ID/config/device_id.json" && exit 1

    # Run the smoke test normally
    xvfb-run --auto-servernum cargo run -p "$PACKAGE" -- smoke-test

    # Make sure the files were written in the right paths
    # TODO: Inject some bogus sign-in sequence to test the actor_name file
    stat "$HOME/.cache/$BUNDLE_ID/data/logs/"connlib*log
    stat "$HOME/.config/$BUNDLE_ID/config/advanced_settings.json"
    stat "$HOME/.config/$BUNDLE_ID/config/device_id.json"

    # Clean up the files but not the folders
    rm -rf "$HOME/.cache/$BUNDLE_ID/data/logs"
    rm "$HOME/.config/$BUNDLE_ID/config/advanced_settings.json"
    rm "$HOME/.config/$BUNDLE_ID/config/device_id.json"
}

function crash_test() {
    # Delete the crash file if present
    rm -f "$DUMP_PATH"

    # Fail if it returns success, this is supposed to crash
    xvfb-run --auto-servernum cargo run -p "$PACKAGE" -- --crash && exit 1

    # Fail if the crash file wasn't written
    stat "$DUMP_PATH"

    # Clean up
    rm "$DUMP_PATH"
}

# Run the tests twice to make sure it's okay for the directories to stay intact,
# and to make sure the tests can cycle.
smoke_test
crash_test
smoke_test
crash_test

# I'm not sure if the last command is handled specially, so explicitly exit with 0
exit 0
