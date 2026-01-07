#!/usr/bin/env bash

setup_mock_dir() {
    if [ -n "${MOCK_DIR:-}" ]; then
        return 0
    fi

    export MOCK_DIR="$BATS_TEST_TMPDIR/mocks"
    mkdir -p "$MOCK_DIR"
    export PATH="$MOCK_DIR:$PATH"
}

mock_sudo() {
    setup_mock_dir
    cat >"$MOCK_DIR/sudo" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$MOCK_DIR/sudo"
}

mock_systemctl() {
    setup_mock_dir
    export SYSTEMCTL_CALLS_LOG="$BATS_TEST_TMPDIR/systemctl_calls.log"
    cat >"$MOCK_DIR/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$SYSTEMCTL_CALLS_LOG"
exit 0
EOF
    chmod +x "$MOCK_DIR/systemctl"
}

mock_systemd_sysusers() {
    setup_mock_dir
    cat >"$MOCK_DIR/systemd-sysusers" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$MOCK_DIR/systemd-sysusers"
}

mock_usermod() {
    setup_mock_dir
    export USERMOD_CALLS_LOG="$BATS_TEST_TMPDIR/usermod_calls.log"
    cat >"$MOCK_DIR/usermod" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$USERMOD_CALLS_LOG"
exit 0
EOF
    chmod +x "$MOCK_DIR/usermod"
}

mock_id() {
    setup_mock_dir
    cat >"$MOCK_DIR/id" <<'EOF'
#!/usr/bin/env bash
# Handle `id -un <uid>` for PKEXEC_UID detection
if [[ "$1" == "-un" ]]; then
    if [ -n "${MOCK_ID_USER:-}" ]; then
        echo "$MOCK_ID_USER"
        exit 0
    fi
    exit 1
fi

# Handle `id -nG <user>` for group membership check
if [[ "$1" == "-nG" ]]; then
    if [ "${MOCK_USER_IN_GROUP:-}" == "true" ]; then
        echo "firezone-client"
    else
        echo "users"
    fi
    exit 0
fi

exit 0
EOF
    chmod +x "$MOCK_DIR/id"
}

mock_who() {
    setup_mock_dir
    cat >"$MOCK_DIR/who" <<'EOF'
#!/usr/bin/env bash
if [ -n "${MOCK_WHO_USER:-}" ]; then
    echo "$MOCK_WHO_USER :0 2024-01-01 00:00"
fi
exit 0
EOF
    chmod +x "$MOCK_DIR/who"
}

cleanup_logs() {
    rm -f "$SYSTEMCTL_CALLS_LOG"
    rm -f "$USERMOD_CALLS_LOG"
}

assert_systemctl_not_called() {
    [ ! -f "$SYSTEMCTL_CALLS_LOG" ]
}

assert_usermod_called_with() {
    local expected_user="$1"
    [ -f "$USERMOD_CALLS_LOG" ]
    grep -q -- "-aG firezone-client $expected_user" "$USERMOD_CALLS_LOG"
}

assert_usermod_not_called() {
    [ ! -f "$USERMOD_CALLS_LOG" ]
}
