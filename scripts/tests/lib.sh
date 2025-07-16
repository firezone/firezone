#!/usr/bin/env bash

set -euox pipefail

function client() {
    docker compose exec -it client "$@"
}

function gateway() {
    docker compose exec -it gateway "$@"
}

function relay1() {
    docker compose exec -it relay-1 "$@"
}

function relay2() {
    docker compose exec -it relay-2 "$@"
}

function install_iptables_drop_rules() {
    # Execute within the client container because doing so from the host is not reliable in CI.
    docker compose exec -it client /bin/sh -c 'iptables -A OUTPUT -s 172.28.0.105 -d 172.28.0.100 -j DROP'
    docker compose exec -it client /bin/sh -c 'iptables -A INPUT -s 172.28.0.100 -d 172.28.0.105 -j DROP'
    trap remove_iptables_drop_rules EXIT # Cleanup after us
}

function remove_iptables_drop_rules() {
    docker compose exec -it client /bin/sh -c 'iptables -D OUTPUT -s 172.28.0.105 -d 172.28.0.100 -j DROP'
    docker compose exec -it client /bin/sh -c 'iptables -D INPUT -s 172.28.0.100 -d 172.28.0.105 -j DROP'
}

function client_curl_resource() {
    client curl --connect-timeout 30 --fail "$1" >/dev/null
}

function client_ping_resource() {
    client timeout 30 \
        sh -c "until ping -W 1 -c 1 $1 &>/dev/null; do true; done"
}

function client_nslookup() {
    # Skip the first 3 lines so that grep won't see the DNS server IP
    # `tee` here copies stdout to stderr
    client timeout 30 sh -c "nslookup $1 | tee >(cat 1>&2) | tail -n +4"
}

function assert_equals() {
    local actual="$1"
    local expected="$2"

    if [[ "$expected" != "$actual" ]]; then
        echo "Expected $expected but got $actual"
        exit 1
    fi
}

function process_state() {
    local container="$1"

    docker compose exec "$container" ps --format state= -p 1 # In a container, our main process is always PID 1
}

function assert_process_state {
    local container="$1"
    local expected_state="$2"

    assert_equals "$(process_state "$container")" "$expected_state"
}

function create_token_file {
    CONFIG_DIR=/etc/dev.firezone.client
    TOKEN_PATH="$CONFIG_DIR/token"

    sudo mkdir "$CONFIG_DIR"
    sudo touch "$TOKEN_PATH"
    sudo chmod 600 "$TOKEN_PATH"
    echo "n.SFMyNTY.g2gDaANtAAAAJGM4OWJjYzhjLTkzOTItNGRhZS1hNDBkLTg4OGFlZjZkMjhlMG0AAAAkN2RhN2QxY2QtMTExYy00NGE3LWI1YWMtNDAyN2I5ZDIzMGU1bQAAACtBaUl5XzZwQmstV0xlUkFQenprQ0ZYTnFJWktXQnMyRGR3XzJ2Z0lRdkZnbgYAGUmu74wBYgABUYA.UN3vSLLcAMkHeEh5VHumPOutkuue8JA6wlxM9JxJEPE" | sudo tee "$TOKEN_PATH" >/dev/null

    # Also put it in `token.txt` for backwards compat, until pull #4666 merges and is
    # cut into a release.
    sudo cp "$TOKEN_PATH" "$TOKEN_PATH.txt"
}
