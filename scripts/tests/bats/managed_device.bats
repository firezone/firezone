#!/usr/bin/env bats

LIB_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
LIB="$LIB_DIR/kotlin/android/mise-tasks/managed-device/lib.sh"

setup() {
    export LIB
    export MOCK_DIR="$BATS_TEST_TMPDIR/mocks"
    export PATH="$MOCK_DIR:$PATH"
    export STUB_REFUSAL="java.lang.IllegalStateException: Not allowed to set the device owner because there are already some accounts on the device."

    mkdir -p "$MOCK_DIR"

    create_adb_mock
}

# Stands in for the device, answering out of what each test put in the environment. The device
# owner is refused STUB_REFUSALS times before it is granted.
create_adb_mock() {
    cat >"$MOCK_DIR/adb" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-} ${2:-} ${3:-}" in
"shell dpm list-owners")
    echo "${STUB_OWNERS:-}"
    exit "${STUB_OWNERS_STATUS:-0}"
    ;;
"shell dumpsys account")
    echo "${STUB_ACCOUNTS:-}"
    ;;
"shell dpm set-device-owner")
    attempts=$(($(cat "$MOCK_DIR/attempts" 2>/dev/null || echo 0) + 1))
    echo "$attempts" >"$MOCK_DIR/attempts"

    if [ "$attempts" -le "${STUB_REFUSALS:-0}" ]; then
        echo "$STUB_REFUSAL"
        exit 255
    fi

    echo "Success: Device owner set to package dev.firezone.dpc/.AdminReceiver"
    ;;
*)
    echo "unexpected command: $*" >&2
    exit 1
    ;;
esac
EOF
    chmod +x "$MOCK_DIR/adb"
}

# The tasks source the library under these options, so what a failure does to them is part of what
# the checks below are about.
lib() {
    run bash -c "set -Eeuo pipefail; source \"\$LIB\"; $1"
}

@test "reads the user a device owner owns" {
    export STUB_OWNERS="1 owner:
User  0: admin=dev.firezone.dpc/.AdminReceiver,DeviceOwner"

    lib 'managed_user'

    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "reads the user a work profile's owner owns" {
    export STUB_OWNERS="1 owner:
User 11: admin=dev.firezone.dpc/.AdminReceiver,ProfileOwner,ManagedProfileOwner(parentUserId=0)"

    lib 'managed_user'

    [ "$status" -eq 0 ]
    [ "$output" = "11" ]
}

@test "reads no user out of a device the DPC does not own" {
    export STUB_OWNERS="no owners"

    lib 'managed_user'

    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "repeats what a failed listing said" {
    export STUB_OWNERS="Error: unknown command 'list-owners'"
    export STUB_OWNERS_STATUS=255

    lib 'managed_user'

    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown command 'list-owners'"* ]]
}

@test "waits out the refusal a device with no accounts gives after boot" {
    export STUB_REFUSALS=1
    export STUB_ACCOUNTS="Accounts: 0"

    lib 'set_device_owner'

    [ "$status" -eq 0 ]
    [[ "$output" == *"Device owner set to package dev.firezone.dpc"* ]]
    [ "$(cat "$MOCK_DIR/attempts")" -eq 2 ]
}

@test "names the accounts a device owner cannot be set over" {
    export STUB_REFUSALS=99
    export STUB_ACCOUNTS="Accounts: 1
  Account {name=someone@example.com, type=com.example}"

    lib 'set_device_owner'

    [ "$status" -ne 0 ]
    [[ "$output" == *"Account {name=someone@example.com, type=com.example}"* ]]
    [[ "$output" == *"-wipe-data"* ]]
    [ "$(cat "$MOCK_DIR/attempts")" -eq 1 ]
}

@test "gives up on a refusal that is not about accounts" {
    export STUB_REFUSALS=99
    export STUB_REFUSAL="Error: Unknown admin: ComponentInfo{dev.firezone.dpc/dev.firezone.dpc.AdminReceiver}"

    lib 'set_device_owner'

    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown admin"* ]]
    [ "$(cat "$MOCK_DIR/attempts")" -eq 1 ]
}
