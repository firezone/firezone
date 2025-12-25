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
Application.ensure_all_started(:portal)
account_id = \"c89bcc8c-9392-4dae-a40d-888aef6d28e0\"

site = Portal.Repo.get_by!(Portal.Site, account_id: account_id, name: \"$site_name\")
[gateway_id | _] = Portal.Presence.Gateways.Site.list(site.id) |> Map.keys()
[client_id | _] = Portal.Presence.Clients.Account.list(account_id) |> Map.keys()
resource = Portal.Repo.get_by!(Portal.Resource, account_id: account_id, name: \"$resource_name\")

Portal.PubSub.Account.broadcast(account_id, {{:reject_access, gateway_id}, client_id, resource.id})
"
}

function assert_eq() {
    local actual="$1"
    local expected="$2"

    if [[ "$expected" != "$actual" ]]; then
        echo "Expected $expected but got $actual"
        exit 1
    fi
}

function assert_ne() {
    local actual="$1"
    local expected="$2"

    if [[ "$expected" == "$actual" ]]; then
        echo "Expected values to differ but both are $actual"
        exit 1
    fi
}

function assert_gteq() {
    local actual="$1"
    local expected="$2"

    if [ "$actual" -lt "$expected" ]; then
        echo "Expected $actual to be greater than or equal to $expected"
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

    assert_eq "$(process_state "$container")" "$expected_state"
}

function create_token_file {
    CONFIG_DIR=/etc/dev.firezone.client
    TOKEN_PATH="$CONFIG_DIR/token"

    sudo mkdir "$CONFIG_DIR"
    sudo touch "$TOKEN_PATH"
    sudo chmod 600 "$TOKEN_PATH"
    echo "n.SFMyNTY.g2gDaANtAAAAJGM4OWJjYzhjLTkzOTItNGRhZS1hNDBkLTg4OGFlZjZkMjhlMG0AAAAkN2RhN2QxY2QtMTExYy00NGE3LWI1YWMtNDAyN2I5ZDIzMGU1bQAAACtBaUl5XzZwQmstV0xlUkFQenprQ0ZYTnFJWktXQnMyRGR3XzJ2Z0lRdkZnbgYAR_ywiZQBYgABUYA.PLNlzyqMSgZlbQb1QX5EzZgYNuY9oeOddP0qDkTwtGg" | sudo tee "$TOKEN_PATH" >/dev/null

    # Also put it in `token.txt` for backwards compat, until pull #4666 merges and is
    # cut into a release.
    sudo cp "$TOKEN_PATH" "$TOKEN_PATH.txt"
}

# Expects a command to fail (non-zero exit code)
# Usage: expect_error your_command arg1 arg2
function expect_error() {
    if "$@"; then
        return 1
    else
        return 0
    fi
}

# Extract flow logs from gateway for a given protocol
# Returns flow log lines (use with readarray)
# Usage: readarray -t flows < <(get_flow_logs "tcp")
function get_flow_logs() {
    local protocol="$1"

    docker compose logs gateway --since 30s 2>/dev/null |
        grep "flow_logs::${protocol}.*flow completed" || true
}

# Extract a field value from a flow log line
# Usage: get_flow_field <flow_log_line> <field_name>
# Example: get_flow_field "$flow" "inner_dst_ip"
function get_flow_field() {
    local flow_log="$1"
    local field_name="$2"

    echo "$flow_log" | grep -oP "${field_name}=\K[^ ]+" || echo ""
}
