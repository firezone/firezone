#!/usr/bin/env bats

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)/rust/gui-client/src-tauri/linux_package"

load test_helper

setup() {
    mock_sudo
    mock_systemctl
}

teardown() {
    cleanup_logs
}

@test "prerm_rpm: exits 0 during upgrade (param=1) without calling systemctl" {
    run bash "$SCRIPT_DIR/prerm_rpm" 1
    [ "$status" -eq 0 ]
    assert_systemctl_not_called
}

@test "prerm_rpm: exits 0 during removal (param=0)" {
    run bash "$SCRIPT_DIR/prerm_rpm" 0
    [ "$status" -eq 0 ]
}

@test "prerm_rpm: exits 0 during complete removal (param=2)" {
    run bash "$SCRIPT_DIR/prerm_rpm" 2
    [ "$status" -eq 0 ]
}
