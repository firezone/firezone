#!/usr/bin/env bash

set -euo pipefail

BUNDLE_ID="dev.firezone.client"

DEVICE_ID_PATH="/var/lib/$BUNDLE_ID/config/firezone-id.json"
# Normally this is all in $HOME. When using sudo, XDG apparently wants some of it under `/root`?
# I'm guessing the rationale is this:
# - Config can still come from $HOME because the program probably won't write it, and it's not private
# - Cache has to go in `/root` because that could leak private data out of the sudo context, and
#   we don't want an unprivileged user to tamper with that cache and control the sudo context
#   when it reads the cache back.
LOGS_PATH="/root/.cache/$BUNDLE_ID/data/logs"
DUMP_PATH="$LOGS_PATH/last_crash.dmp"
SETTINGS_PATH="$HOME/.config/$BUNDLE_ID/config/advanced_settings.json"

export FIREZONE_DISABLE_SYSTRAY=true
PACKAGE=firezone-gui-client
export RUST_LOG=firezone_gui_client=debug,warn
export WEBKIT_DISABLE_COMPOSITING_MODE=1

cargo build -p "$PACKAGE"

function smoke_test() {
    # Make sure the files we want to check don't exist on the system yet
    sudo stat "$LOGS_PATH" && exit 1
    sudo stat "$SETTINGS_PATH" && exit 1
    sudo stat "$DEVICE_ID_PATH" && exit 1

    # Run the smoke test normally
    sudo xvfb-run --auto-servernum ../target/debug/"$PACKAGE" smoke-test

    # Note the device ID
    DEVICE_ID_1=$(cat "$DEVICE_ID_PATH")

    # Make sure the files were written in the right paths
    # TODO: Inject some bogus sign-in sequence to test the actor_name file
    # https://stackoverflow.com/questions/41321092
    sudo bash -c "stat \"${LOGS_PATH}/\"connlib*log"
    sudo stat "$SETTINGS_PATH"
    sudo stat "$DEVICE_ID_PATH"

    # Run the test again and make sure the device ID is not changed
    sudo xvfb-run --auto-servernum ../target/debug/"$PACKAGE" smoke-test
    DEVICE_ID_2=$(cat "$DEVICE_ID_PATH")

    if [ "$DEVICE_ID_1" != "$DEVICE_ID_2" ]
    then
        echo "The device ID should not change if the file is intact between runs"
        exit 1
    fi

    # Clean up the files but not the folders
    sudo rm -rf "$LOGS_PATH"
    sudo rm "$SETTINGS_PATH"
    sudo rm "$DEVICE_ID_PATH"
}

function crash_test() {
    # Delete the crash file if present
    sudo rm -f "$DUMP_PATH"

    # Fail if it returns success, this is supposed to crash
    sudo xvfb-run --auto-servernum ../target/debug/"$PACKAGE" --crash && exit 1

    # Fail if the crash file wasn't written
    sudo stat "$DUMP_PATH"

    # Clean up
    sudo rm "$DUMP_PATH"
}

# Run the tests twice to make sure it's okay for the directories to stay intact
smoke_test
smoke_test
crash_test
crash_test

# I'm not sure if the last command is handled specially, so explicitly exit with 0
exit 0
