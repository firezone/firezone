#!/usr/bin/env bash

# Put `set -euox` in the top-level scripts directly. If it's only sourced,
# and the source path is wrong, it will not throw an error and it'll be hard
# to debug.
# <https://github.com/firezone/firezone/actions/runs/9602401296/job/26483176628#step:11:12>
set -euox pipefail

BUNDLE_ID="dev.firezone.client"
FZ_GROUP="firezone-client"

LOGS_PATH="$HOME/.cache/$BUNDLE_ID/data/logs"

DUMP_PATH="$LOGS_PATH/last_crash.dmp"
IPC_LOGS_PATH="/var/log/$BUNDLE_ID"
RAN_BEFORE_PATH="$HOME/.local/share/$BUNDLE_ID/data/ran_before.txt"
SETTINGS_PATH="$HOME/.config/$BUNDLE_ID/config/advanced_settings.json"
SYMS_PATH="../target/debug/firezone-gui-client.syms"

PACKAGE=firezone-gui-client
export RUST_LOG=firezone_gui_client=debug,warn
export WEBKIT_DISABLE_COMPOSITING_MODE=1

cargo build -p "$PACKAGE"
cargo install --quiet --locked dump_syms minidump-stackwalk
# The dwp doesn't actually do anything if the exe already has all the debug info
# Getting this to coordinate between Linux and Windows is tricky
dump_syms ../target/debug/firezone-gui-client --output "$SYMS_PATH"
ls -lash ../target/debug

sudo groupadd --force "$FZ_GROUP"
sudo adduser "$USER" "$FZ_GROUP"

# Make the IPC log dir so that the zip export doesn't bail out
sudo mkdir -p "$IPC_LOGS_PATH"

function run_fz_gui() {
    pwd
    # Does what it says
    sudo --preserve-env \
    su --login "$USER" --command \
    "xvfb-run --auto-servernum $PWD/../target/debug/$PACKAGE $*"
}

function smoke_test() {
    # Make sure the files we want to check don't exist on the system yet
    stat "$LOGS_PATH" && exit 1
    stat "$SETTINGS_PATH" && exit 1
    # TODO: The device ID will be written by the tunnel, not the GUI, so we can't check that.
    # stat "$DEVICE_ID_PATH" && exit 1
    stat "$RAN_BEFORE_PATH" && exit 1

    # Run the smoke test normally
    if ! run_fz_gui --no-deep-links smoke-test
    then
        minidump-stackwalk --symbols-path "$SYMS_PATH" "$DUMP_PATH"
        exit 1
    fi

    # Note the device ID
    # DEVICE_ID_1=$(cat "$DEVICE_ID_PATH")

    # Make sure the files were written in the right paths
    # TODO: Inject some bogus sign-in sequence to test the actor_name file
    # https://stackoverflow.com/questions/41321092
    # TODO: Smoke test the IPC service
    # bash -c "stat \"${LOGS_PATH}/\"connlib*log"
    stat "$SETTINGS_PATH"
    # stat "$DEVICE_ID_PATH"
    # `ran_before` is now only written after a successful sign-in
    stat "$RAN_BEFORE_PATH" && exit 1

    # Run the test again and make sure the device ID is not changed
    run_fz_gui --no-deep-links smoke-test
    # DEVICE_ID_2=$(cat "$DEVICE_ID_PATH")

    #if [ "$DEVICE_ID_1" != "$DEVICE_ID_2" ]
    #then
    #    echo "The device ID should not change if the file is intact between runs"
    #    exit 1
    #fi

    # Clean up the files but not the folders
    rm -rf "$LOGS_PATH"
    rm "$SETTINGS_PATH"
    # rm "$DEVICE_ID_PATH"
    rm -f "$RAN_BEFORE_PATH"
}

function crash_test() {
    # Delete the crash file if present
    rm -f "$DUMP_PATH"

    # Fail if it returns success, this is supposed to crash
    run_fz_gui --crash --no-deep-links && exit 1

    # Fail if the crash file wasn't written
    stat "$DUMP_PATH"
}

function get_stacktrace() {
    minidump-stackwalk --symbols-path "$SYMS_PATH" "$DUMP_PATH"
}

# Run the tests twice to make sure it's okay for the directories to stay intact
smoke_test
smoke_test
crash_test
crash_test
get_stacktrace

# Clean up
rm "$DUMP_PATH"
