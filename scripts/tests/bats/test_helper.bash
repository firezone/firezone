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

cleanup_logs() {
    rm -f "$SYSTEMCTL_CALLS_LOG"
}

assert_systemctl_not_called() {
    [ ! -f "$SYSTEMCTL_CALLS_LOG" ]
}
