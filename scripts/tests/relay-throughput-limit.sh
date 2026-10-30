#!/usr/bin/env bash

# Relayed traffic is held to the account's throughput limit, ECN-capable flows
# see Congestion Experienced marks, and a changed limit applies to the existing
# connection.
#
# Requires a relayed connection (symmetric NAT on both sides and a single Relay).

source "./scripts/tests/lib.sh"

ACCOUNT_ID="c89bcc8c-9392-4dae-a40d-888aef6d28e0"

function set_relay_throughput_limit() {
    local mbps="$1"

    # The test environment does not stream database changes, so broadcast the
    # change to the Relay channel like the account changes hook would.
    docker compose exec -T portal bin/portal rpc "
Application.ensure_all_started(:portal)
account = Portal.Repo.get!(Portal.Account, \"$ACCOUNT_ID\")
limits = account.limits || %Portal.Accounts.Limits{}

updated =
  account
  |> Ecto.Changeset.change()
  |> Ecto.Changeset.put_embed(:limits, %{limits | relay_throughput_mbps: $mbps})
  |> Portal.Repo.update!()

Portal.PubSub.Changes.broadcast_account(%Portal.Changes.Change{
  lsn: System.os_time(:nanosecond),
  op: :update,
  old_struct: account,
  struct: updated
})
"

    # The Relay logs the account's new limit in bytes per second once it has received it.
    local bytes_per_second=$((mbps * 125000))
    timeout 30 sh -c "until docker compose logs relay-1 | grep 'Added account to TURN allow list' | grep -q 'bytes_per_second: $bytes_per_second'; do sleep 1; done"
}

# Downloads the given number of bytes through the tunnel and prints the average speed in bytes per second.
function download_bytes() {
    local num_bytes="$1"

    client curl --fail --silent --connect-timeout 10 --max-time 120 \
        --output /dev/null --write-out '%{speed_download}' \
        "http://download.httpbin/bytes?num=$num_bytes" | cut -d. -f1
}

function ce_marked_packets_received_by_client() {
    client awk '/^IpExt:/ { if (!header) { split($0, names); header = 1 } else { for (i = 2; i <= NF; i++) if (names[i] == "InCEPkts") print $i } }' /proc/net/netstat
}

function assert_between() {
    local actual="$1"
    local min="$2"
    local max="$3"

    if ((actual < min || actual > max)); then
        echo "Expected $actual to be between $min and $max"
        exit 1
    fi
}

# Linux only accepts ECN when the peer asks for it, so the downloading Client must ask.
client sysctl -w net.ipv4.tcp_ecn=1

set_relay_throughput_limit 5

ce_before=$(ce_marked_packets_received_by_client)
speed=$(download_bytes 5000000)
ce_after=$(ce_marked_packets_received_by_client)

# 5 Mbps = 625 kB/s. WireGuard and TCP/IP headers count against the limit too.
# ECN-capable flows back off from 80% of the limit, so only bound the speed from above.
assert_between "$speed" 1 690000
assert_gteq "$((ce_after - ce_before))" 1

set_relay_throughput_limit 25

speed=$(download_bytes 20000000)

# 25 Mbps = 3125 kB/s; exceeding the previous limit shows that the new one applies.
assert_between "$speed" 1000000 3440000
