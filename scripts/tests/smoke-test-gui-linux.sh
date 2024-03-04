#!/usr/bin/env bash

set -euo pipefail

BUNDLE_ID="dev.firezone.client"
DEVICE_ID_PATH="$HOME/.config/$BUNDLE_ID/config/device_id.json"
DUMP_PATH="$HOME/.cache/$BUNDLE_ID/data/logs/last_crash.dmp"
export FIREZONE_DISABLE_SYSTRAY=true
PACKAGE=firezone-gui-client
export RUST_LOG=firezone_gui_client=debug,warn
export WEBKIT_DISABLE_COMPOSITING_MODE=1

function smoke_test() {
    # Make sure the files we want to check don't exist on the system yet
    stat "$HOME/.cache/$BUNDLE_ID/data/logs" && exit 1
    stat "$HOME/.config/$BUNDLE_ID/config/advanced_settings.json" && exit 1
    stat "$DEVICE_ID_PATH" && exit 1

    # Run the smoke test normally
    xvfb-run --auto-servernum cargo run -p "$PACKAGE" -- smoke-test

    # Note the device ID
    DEVICE_ID_1=$(cat "$DEVICE_ID_PATH")

    # Make sure the files were written in the right paths
    # TODO: Inject some bogus sign-in sequence to test the actor_name file
    stat "$HOME/.cache/$BUNDLE_ID/data/logs/"connlib*log
    stat "$HOME/.config/$BUNDLE_ID/config/advanced_settings.json"
    stat "$DEVICE_ID_PATH"

    # Run the test again and make sure the device ID is not changed
    xvfb-run --auto-servernum cargo run -p "$PACKAGE" -- smoke-test
    DEVICE_ID_2=$(cat "$DEVICE_ID_PATH")

    if [ "$DEVICE_ID_1" != "$DEVICE_ID_2" ]
    then
        echo "The device ID should not change if the file is intact between runs"
        exit 1
    fi

    # Clean up the files but not the folders
    rm -rf "$HOME/.cache/$BUNDLE_ID/data/logs"
    rm "$HOME/.config/$BUNDLE_ID/config/advanced_settings.json"
    rm "$DEVICE_ID_PATH"
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

# Run the tests twice to make sure it's okay for the directories to stay intact
smoke_test
smoke_test
crash_test
crash_test

# I'm not sure if the last command is handled specially, so explicitly exit with 0
exit 0
