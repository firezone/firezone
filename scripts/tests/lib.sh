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

function client_curl_resource() {
    client curl --connect-timeout 10 --fail "$1" >/dev/null
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

function api_send_reject_access() {
    local site_name="$1"
    local resource_name="$2"

    docker compose exec -T api bin/api rpc "
Application.ensure_all_started(:domain)
account_id = \"c89bcc8c-9392-4dae-a40d-888aef6d28e0\"

[gateway_group] = Domain.Gateways.Group.Query.not_deleted() |> Domain.Gateways.Group.Query.by_account_id(account_id) |> Domain.Gateways.Group.Query.by_name(\"$site_name\") |> Domain.Repo.all()
[gateway_id | _] = Domain.Gateways.Presence.Group.list(gateway_group.id) |> Map.keys()
[client_id | _] = Domain.Clients.Presence.Account.list(account_id) |> Map.keys()
[resource] = Domain.Resources.Resource.Query.not_deleted() |> Domain.Resources.Resource.Query.by_account_id(account_id) |> Domain.Repo.all() |> Enum.filter(&(&1.name == \"$resource_name\"))

Domain.PubSub.Account.broadcast(account_id, {{:reject_access, gateway_id}, client_id, resource.id})
"
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

# Expects a command to fail (non-zero exit code)
# Usage: expect_error your_command arg1 arg2
function expect_error() {
    if "$@"; then
        echo "ERROR: Command succeeded when it should have failed: $*"
        return 1
    else
        echo "✓ Command failed as expected: $*"
        return 0
    fi
}

# Expects a command to fail with a specific exit code
# Usage: expect_error_code 255 your_command arg1 arg2
function expect_error_code() {
    local expected_code=$1
    shift

    "$@"
    local actual_code=$?

    if [ $actual_code -eq $expected_code ]; then
        echo "✓ Command returned expected code $expected_code: $*"
        return 0
    else
        echo "ERROR: Expected code $expected_code but got $actual_code: $*"
        return 1
    fi
}
