#!/usr/bin/env bash
# Usage: This is made for CI, so it will change system-wide files without asking.
# Read it before running on a dev system.
# This script must run from an elevated shell so that Firezone won't try to elevate.

set -euox pipefail

# This prevents a `shellcheck` lint warning about using an unset CamelCase var
if [[ -z "$ProgramData" ]]; then
    echo "The env var \$ProgramData should be set to \`C:\ProgramData\` or similar"
    exit 1
fi

BUNDLE_ID="dev.firezone.client"
DUMP_PATH="$LOCALAPPDATA/$BUNDLE_ID/data/logs/last_crash.dmp"
IPC_LOGS_PATH="$ProgramData/$BUNDLE_ID/data/logs"
PACKAGE=firezone-gui-client

# Make the IPC log dir so that the zip export doesn't bail out
mkdir -p "$IPC_LOGS_PATH"

function smoke_test() {
    # This array used to have more items
    # TODO: Smoke-test the IPC service
    files=(
        "$LOCALAPPDATA/$BUNDLE_ID/config/advanced_settings.json"
    )

    # Make sure the files we want to check don't exist on the system yet
    # I'm leaning on ChatGPT and `shellcheck` for the syntax here.
    # Maybe this is about ready to be translated into Python or Rust.
    for file in "${files[@]}"
    do
        stat "$file" && exit 1
    done

    # Run the smoke test normally
    $PWD/../target/debug/$PACKAGE smoke-test

    # Make sure the files were written in the right paths
    for file in "${files[@]}"
    do
        stat "$file"
    done

    # Clean up so the test can be cycled
    for file in "${files[@]}"
    do
        rm "$file"
    done
}

function crash_test() {
    # Delete the crash file if present
    rm -f "$DUMP_PATH"

    # Fail if it returns success, this is supposed to crash
    $PWD/../target/debug/$PACKAGE --crash && exit 1

    # Fail if the crash file wasn't written
    stat "$DUMP_PATH"
}

function get_stacktrace() {
    # Per `crash_handling.rs`
    SYMS_PATH="../target/debug/firezone-gui-client.syms"
    dump_syms ../target/debug/firezone_gui_client.pdb ../target/debug/firezone-gui-client.exe --output "$SYMS_PATH"
    ls -lash ../target/debug
    minidump-stackwalk --symbols-path "$SYMS_PATH" "$DUMP_PATH"
}

smoke_test
smoke_test
crash_test
get_stacktrace

# Clean up
rm "$DUMP_PATH"
