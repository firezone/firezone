#!/usr/bin/env bats

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
SCRIPT="$SCRIPT_DIR/scripts/gateway-systemd-install.sh"

setup() {
    export TEST_ROOT="$BATS_TEST_TMPDIR/root"
    export MOCK_DIR="$BATS_TEST_TMPDIR/mocks"
    export PATH="$MOCK_DIR:$PATH"

    mkdir -p "$TEST_ROOT" "$MOCK_DIR"

    create_sudo_mock
    create_id_mock
    create_systemctl_mock
    create_chown_mock
}

create_sudo_mock() {
    cat >"$MOCK_DIR/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

map_path() {
    case "$1" in
        /etc/* | /usr/local/*)
            printf '%s%s' "$TEST_ROOT" "$1"
            ;;
        *)
            printf '%s' "$1"
            ;;
    esac
}

cmd=$1
shift

case "$cmd" in
    groupadd | useradd | systemctl)
        exit 0
        ;;
    test)
        mapped=()
        for arg in "$@"; do
            mapped+=("$(map_path "$arg")")
        done
        command test "${mapped[@]}"
        ;;
    install)
        if [ "${1:-}" = "-d" ]; then
            dest="${*: -1}"
            mkdir -p "$(map_path "$dest")"
        else
            echo "unexpected install command: install $*" >&2
            exit 1
        fi
        ;;
    sh)
        if [ "${1:-}" != "-c" ]; then
            echo "unexpected sh command: sh $*" >&2
            exit 1
        fi

        script=$2
        shift 2

        mapped_args=()
        for arg in "$@"; do
            mapped_args+=("$(map_path "$arg")")
        done

        PATH="$MOCK_DIR:$PATH" command sh -c "$script" "${mapped_args[@]}"
        ;;
    tee)
        dest=$(map_path "$1")
        mkdir -p "$(dirname "$dest")"
        cat >"$dest"
        ;;
    chmod)
        mode=$1
        dest=$(map_path "$2")
        chmod "$mode" "$dest"
        ;;
    *)
        echo "unexpected sudo command: $cmd $*" >&2
        exit 1
        ;;
esac
EOF
    chmod +x "$MOCK_DIR/sudo"
}

create_id_mock() {
    cat >"$MOCK_DIR/id" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-u" ] && [ "${2:-}" = "firezone" ]; then
    exit 1
fi

command id "$@"
EOF
    chmod +x "$MOCK_DIR/id"
}

create_systemctl_mock() {
    cat >"$MOCK_DIR/systemctl" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
    echo "systemd ${MOCK_SYSTEMD_VERSION:-255}"
    exit 0
fi

exit 0
EOF
    chmod +x "$MOCK_DIR/systemctl"
}

create_chown_mock() {
    cat >"$MOCK_DIR/chown" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$MOCK_DIR/chown"
}

service_file() {
    echo "$TEST_ROOT/etc/systemd/system/firezone-gateway.service"
}

token_file() {
    echo "$TEST_ROOT/etc/firezone/gateway-token"
}

init_script() {
    echo "$TEST_ROOT/usr/local/bin/firezone-gateway-init"
}

file_mode() {
    stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

refute_file_contains() {
    local pattern=$1
    local file=$2

    if grep -q -- "$pattern" "$file"; then
        echo "Expected $file not to contain $pattern" >&2
        return 1
    fi
}

@test "gateway-systemd-install: stores token as a systemd credential" {
    run env \
        FIREZONE_ID="test-gateway-id" \
        FIREZONE_TOKEN="test-secret-token" \
        "$SCRIPT"

    [ "$status" -eq 0 ]
    [ -f "$(service_file)" ]
    [ -f "$(token_file)" ]

    grep -q '^LoadCredential=FIREZONE_TOKEN:/etc/firezone/gateway-token$' "$(service_file)"
    grep -q '^Environment="FIREZONE_ID=test-gateway-id"$' "$(service_file)"
    refute_file_contains 'test-secret-token' "$(service_file)"
    refute_file_contains 'FIREZONE_TOKEN=' "$(service_file)"
    grep -q '^test-secret-token$' "$(token_file)"
    [ "$(file_mode "$(token_file)")" = "400" ]
}

@test "gateway-systemd-install: generated init script uses hardcoded artifact URL and verifies checksums" {
    run env \
        FIREZONE_ID="test-gateway-id" \
        FIREZONE_TOKEN="test-secret-token" \
        "$SCRIPT"

    [ "$status" -eq 0 ]
    [ -f "$(init_script)" ]

    grep -q '^ARTIFACT_BASE_URL="https://www.firezone.dev/dl/firezone-gateway"$' "$(init_script)"
    grep -q '^GATEWAY_VERSION="1.5.2"$' "$(init_script)"
    grep -q 'download_url="$ARTIFACT_BASE_URL/$GATEWAY_VERSION/$arch"' "$(init_script)"
    [ "$(grep -Ec 'expected_sha256="[0-9a-f]{64}"' "$(init_script)")" -eq 3 ]
    grep -q 'failed checksum verification' "$(init_script)"
    refute_file_contains 'CURRENT_GATEWAY_VERSION' "$SCRIPT"
    refute_file_contains 'FIREZONE_VERSION' "$SCRIPT"
    refute_file_contains 'FIREZONE_VERSION' "$(init_script)"
    refute_file_contains 'FIREZONE_ARTIFACT_URL' "$SCRIPT"
    refute_file_contains 'FIREZONE_ARTIFACT_URL' "$(init_script)"
}

@test "gateway-systemd-install: migrates token and ID from legacy unit" {
    export SERVICE_FILE="$BATS_TEST_TMPDIR/legacy-firezone-gateway.service"
    export TOKEN_FILE="$BATS_TEST_TMPDIR/gateway-token"

    cat >"$SERVICE_FILE" <<'EOF'
[Service]
Environment="FIREZONE_ID=legacy-gateway-id"
Environment="FIREZONE_TOKEN=legacy-secret-token"
EOF

    run "$SCRIPT"

    [ "$status" -eq 0 ]
    grep -q "^LoadCredential=FIREZONE_TOKEN:$TOKEN_FILE$" "$SERVICE_FILE"
    grep -q '^Environment="FIREZONE_ID=legacy-gateway-id"$' "$SERVICE_FILE"
    refute_file_contains 'legacy-secret-token' "$SERVICE_FILE"
    refute_file_contains 'FIREZONE_TOKEN=' "$SERVICE_FILE"
    grep -q '^legacy-secret-token$' "$TOKEN_FILE"
    [ "$(file_mode "$TOKEN_FILE")" = "400" ]
}

@test "gateway-systemd-install: rejects systemd versions without LoadCredential support" {
    run env \
        FIREZONE_ID="test-gateway-id" \
        FIREZONE_TOKEN="test-secret-token" \
        MOCK_SYSTEMD_VERSION="219" \
        "$SCRIPT"

    [ "$status" -ne 0 ]
    [[ "$output" == *"systemd 247 or newer is required"* ]]
    [ ! -f "$(service_file)" ]
    [ ! -f "$(token_file)" ]
}
