#!/usr/bin/env bats

CLI_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)/swift/apple/Firezone/CLI"

setup() {
    # Canonical, so the paths the wrapper reports can be compared against it directly.
    BUNDLE="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/Firezone.app"
    export BUNDLE
    export LINK_DIR="$BATS_TEST_TMPDIR/bin"

    mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources/bin" "$LINK_DIR"
    cp "$CLI_DIR/firezone" "$BUNDLE/Contents/Resources/bin/firezone"
    chmod +x "$BUNDLE/Contents/Resources/bin/firezone"

    create_client_mock

    ln -s "$BUNDLE/Contents/Resources/bin/firezone" "$LINK_DIR/firezone"
}

# Stands in for the client, reporting where the wrapper started it and what it passed on.
create_client_mock() {
    cat >"$BUNDLE/Contents/MacOS/firezone-cli" <<'EOF'
#!/usr/bin/env bash
echo "$0"
echo "args: $*"
EOF
    chmod +x "$BUNDLE/Contents/MacOS/firezone-cli"
}

started_client() {
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "$BUNDLE/Contents/MacOS/firezone-cli" ]
}

@test "starts the client inside the bundle and passes the arguments on" {
    run "$BUNDLE/Contents/Resources/bin/firezone" status --debug

    started_client
    [ "${lines[1]}" = "args: status --debug" ]
}

@test "starts the client when a symlink is what was invoked" {
    run "$LINK_DIR/firezone"

    started_client
}

@test "starts the client when the symlink was found on the PATH" {
    run env PATH="$LINK_DIR:$PATH" firezone

    started_client
}

@test "starts the client when invoked by a relative path" {
    cd "$BUNDLE/Contents/Resources/bin"

    run ./firezone

    started_client
}

@test "starts the client through a chain of symlinks" {
    ln -s "$LINK_DIR/firezone" "$LINK_DIR/fz"

    run "$LINK_DIR/fz"

    started_client
}
