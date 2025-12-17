#!/usr/bin/env bats

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)/rust/gui-client/src-tauri/linux_package"

load test_helper

setup() {
    mock_sudo
    mock_systemctl
    mock_systemd_sysusers
    mock_usermod
    mock_id
    mock_who
}

teardown() {
    cleanup_logs
}

@test "postinst: adds user with dot in username to firezone-client group" {
    # Simulate a username with a dot (e.g., john.doe)
    export SUDO_USER="john.doe"

    run bash "$SCRIPT_DIR/postinst"
    [ "$status" -eq 0 ]

    # Verify usermod was called with the correct username
    assert_usermod_called_with "john.doe"
}

@test "postinst: adds user from PKEXEC_UID to firezone-client group" {
    export PKEXEC_UID="1000"
    export MOCK_ID_USER="testuser"

    run bash "$SCRIPT_DIR/postinst"
    [ "$status" -eq 0 ]

    assert_usermod_called_with "testuser"
}

@test "postinst: adds user from SUDO_USER to firezone-client group" {
    export SUDO_USER="sudouser"

    run bash "$SCRIPT_DIR/postinst"
    [ "$status" -eq 0 ]

    assert_usermod_called_with "sudouser"
}

@test "postinst: adds user from display session when no PKEXEC_UID or SUDO_USER" {
    unset PKEXEC_UID
    unset SUDO_USER
    export MOCK_WHO_USER="displayuser"

    run bash "$SCRIPT_DIR/postinst"
    [ "$status" -eq 0 ]

    assert_usermod_called_with "displayuser"
}

@test "postinst: fails when no user can be detected" {
    unset PKEXEC_UID
    unset SUDO_USER
    export MOCK_WHO_USER=""

    run bash "$SCRIPT_DIR/postinst"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Could not detect a user"* ]]
}

@test "postinst: skips usermod if user already in firezone-client group" {
    export SUDO_USER="existinguser"
    export MOCK_USER_IN_GROUP="true"

    run bash "$SCRIPT_DIR/postinst"
    [ "$status" -eq 0 ]

    assert_usermod_not_called
}

@test "postinst: handles username with multiple dots" {
    export SUDO_USER="first.middle.last"

    run bash "$SCRIPT_DIR/postinst"
    [ "$status" -eq 0 ]

    assert_usermod_called_with "first.middle.last"
}
