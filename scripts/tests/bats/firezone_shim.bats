#!/usr/bin/env bats

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)/rust/gateway/debian/firezone"

bats_require_minimum_version 1.5.0

load test_helper

setup() {
    setup_mock_dir
    export GATEWAY_CALLS_LOG="$BATS_TEST_TMPDIR/gateway_calls.log"
    cat >"$MOCK_DIR/firezone-gateway" <<'MOCK'
#!/usr/bin/env bash
echo "$*" >> "$GATEWAY_CALLS_LOG"
echo "gateway stdout"
MOCK
    chmod +x "$MOCK_DIR/firezone-gateway"
}

@test "firezone-shim: forwards gateway commands and warns on stderr" {
    run --separate-stderr bash "$SCRIPT" gateway authenticate --replace

    [ "$status" -eq 0 ]
    [ "$output" = "gateway stdout" ]
    [[ "$stderr" == *"deprecated"* ]]
    [[ "$stderr" == *'`firezone-gateway authenticate --replace`'* ]]
    [ "$(cat "$GATEWAY_CALLS_LOG")" = "authenticate --replace" ]
}

@test "firezone-shim: rejects anything but the gateway component" {
    run --separate-stderr bash "$SCRIPT" relay authenticate

    [ "$status" -eq 2 ]
    [ -z "$output" ]
    [[ "$stderr" == *"firezone-gateway --help"* ]]
    [ ! -f "$GATEWAY_CALLS_LOG" ]
}
