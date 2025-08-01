#!/usr/bin/env bash

set -euox pipefail

function client() {
    docker compose exec -T client "$@"
}

function gateway() {
    docker compose exec -T gateway "$@"
}

function relay1() {
    docker compose exec -T relay-1 "$@"
}

function relay2() {
    docker compose exec -T relay-2 "$@"
}

# Takes two optional arguments to force the client and gateway to use a specific IP stack.
# 1. client_stack: "ipv4", "ipv6"
# 2. gateway_stack: "ipv4", "ipv6"
#
# By default, the client and gateway will use happy eyeballs to use pick the first working IP stack.
function force_relayed_connections() {
    # Install `iptables` to have it available in the compatibility tests
    client apk add --no-cache iptables

    # Execute within the client container because doing so from the host is not reliable in CI.
    client iptables -A OUTPUT -d 172.28.0.105 -j DROP
    client ip6tables -A OUTPUT -d 172:28:0::105 -j DROP

    local client_stack="${1:-}"
    local gateway_stack="${2:-}"

    # If both are empty, we don't care which stack they use; just return
    if [[ -z "$client_stack" && -z "$gateway_stack" ]]; then
        return
    fi

    gateway apk add --no-cache iptables

    if [[ "$client_stack" == "ipv4" && "$gateway_stack" == "ipv4" ]]; then
        client ip6tables -A OUTPUT -d $RELAY_1_PUBLIC_IP6_ADDR -j DROP
        client ip6tables -A OUTPUT -d $RELAY_2_PUBLIC_IP6_ADDR -j DROP
        gateway ip6tables -A OUTPUT -d $RELAY_1_PUBLIC_IP6_ADDR -j DROP
        gateway ip6tables -A OUTPUT -d $RELAY_2_PUBLIC_IP6_ADDR -j DROP
    elif [[ "$client_stack" == "ipv4" && "$gateway_stack" == "ipv6" ]]; then
        client ip6tables -A OUTPUT -d $RELAY_1_PUBLIC_IP6_ADDR -j DROP
        client ip6tables -A OUTPUT -d $RELAY_2_PUBLIC_IP6_ADDR -j DROP
        gateway iptables -A OUTPUT -d $RELAY_1_PUBLIC_IP4_ADDR -j DROP
        gateway iptables -A OUTPUT -d $RELAY_2_PUBLIC_IP4_ADDR -j DROP
    elif [[ "$client_stack" == "ipv6" && "$gateway_stack" == "ipv4" ]]; then
        client iptables -A OUTPUT -d $RELAY_1_PUBLIC_IP4_ADDR -j DROP
        client iptables -A OUTPUT -d $RELAY_2_PUBLIC_IP4_ADDR -j DROP
        gateway ip6tables -A OUTPUT -d $RELAY_1_PUBLIC_IP6_ADDR -j DROP
        gateway ip6tables -A OUTPUT -d $RELAY_2_PUBLIC_IP6_ADDR -j DROP
    elif [[ "$client_stack" == "ipv6" && "$gateway_stack" == "ipv6" ]]; then
        client iptables -A OUTPUT -d $RELAY_1_PUBLIC_IP4_ADDR -j DROP
        client iptables -A OUTPUT -d $RELAY_2_PUBLIC_IP4_ADDR -j DROP
        gateway iptables -A OUTPUT -d $RELAY_1_PUBLIC_IP4_ADDR -j DROP
        gateway iptables -A OUTPUT -d $RELAY_2_PUBLIC_IP4_ADDR -j DROP
    else
        echo "Invalid stack combination: client_stack=$client_stack, gateway_stack=$gateway_stack"
        exit 1
    fi
}

function client_curl_resource() {
    client curl --connect-timeout 5 --fail "$1" >/dev/null
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
