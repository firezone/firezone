#!/usr/bin/env bash

# Runs one iperf3 benchmark scenario through the docker-compose topology,
# mirroring .github/workflows/_perf_tests.yml. Results (iperf JSON + summary,
# and optionally perf profiles + flamegraphs) land in bench-results/.
#
# Usage: run.sh [--flavour direct|relayed] [--profile] [--label NAME] TEST
#
#   TEST: tcp-client2server | tcp-server2client | udp-client2server | udp-server2client
#
# The stack is left running for fast iteration. After a code change:
#   scripts/benchmark/build-binaries.sh firezone-gateway
#   docker compose up -d --build gateway
#   scripts/benchmark/run.sh tcp-client2server
# Tear down with `docker compose down` (add `-v` to also reset the database).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

FLAVOUR="direct"
PROFILE=0
LABEL=""
TEST=""

while [ $# -gt 0 ]; do
    case "$1" in
    --flavour)
        FLAVOUR="$2"
        shift 2
        ;;
    --profile)
        PROFILE=1
        shift
        ;;
    --label)
        LABEL="$2"
        shift 2
        ;;
    *)
        TEST="$1"
        shift
        ;;
    esac
done

case "$TEST" in
tcp-client2server | tcp-server2client | udp-client2server | udp-server2client) ;;
*)
    echo "Usage: run.sh [--flavour direct|relayed] [--profile] [--label NAME] TEST" >&2
    exit 1
    ;;
esac

# Compose files: the bench overlay swaps in locally-built release binaries; the
# IPv4 overlay is needed on kernels without IPv6 (e.g. Claude Code web VMs).
COMPOSE_FILE="docker-compose.yml:scripts/benchmark/compose.bench.yml"
if [ ! -f /proc/net/if_inet6 ]; then
    COMPOSE_FILE="docker-compose.yml:scripts/benchmark/compose.ipv4.yml:scripts/benchmark/compose.bench.yml"
fi
export COMPOSE_FILE
export COMPOSE_PARALLEL_LIMIT=1
export FIREZONE_INC_BUF=true

if [ "$FLAVOUR" = "relayed" ]; then
    export CLIENT_MASQUERADE=random
    export UDP_BITRATE=300M
fi

retry() {
    local attempt=1
    while ! "$@"; do
        if [ $attempt -ge 5 ]; then
            echo "Command failed after 5 attempts: $*" >&2
            return 1
        fi
        echo "Attempt $attempt/5 failed, retrying in 5s..." >&2
        sleep 5
        attempt=$((attempt + 1))
    done
}

echo "==> Building router images"
docker compose build client-1-router gateway-router relay-1-router relay-2-router portal-router

echo "==> Building benchmark images from rust/ binaries"
for binary in firezone-headless-client firezone-gateway firezone-relay; do
    [ -f "rust/$binary" ] || {
        echo "ERROR: rust/$binary not found; run scripts/benchmark/build-binaries.sh first" >&2
        exit 1
    }
done
docker compose build client-1 gateway relay-1 relay-2

echo "==> Migrating and seeding the database"
retry docker compose up -d postgres
if docker compose exec postgres psql -U postgres -d firezone_dev -tAc "select 1 from accounts limit 1" 2>/dev/null | grep -q 1; then
    echo "    database already seeded"
else
    docker compose run --rm elixir /bin/sh -c 'mix ecto.migrate && mix ecto.seed'
fi

echo "==> Starting the stack"
retry docker compose up -d iperf3
retry docker compose up -d portal --no-build
retry docker compose up -d relay-1 relay-2 --no-build
retry docker compose up -d gateway --no-build
retry docker compose up -d client-1 --no-build
retry docker compose up -d network-config

RESULTS_DIR="bench-results/${LABEL:-$(date +%Y%m%d)}"
mkdir -p "$RESULTS_DIR"
# Unique per invocation so repeat runs under the same label accumulate
# (the test scripts append to $TEST_NAME.json).
TEST_NAME="$RESULTS_DIR/$FLAVOUR-$TEST-$(date +%H%M%S)"
export TEST_NAME

perf_pids=()
if [ "$PROFILE" = "1" ]; then
    perf_event="cycles"
    if perf stat -e cycles -x, true 2>&1 | grep -q "not supported"; then
        perf_event="cpu-clock" # works without a hardware PMU (e.g. in VMs)
    fi

    client_pids=$(pgrep -x firezone-headle | paste -sd, -)
    gateway_pids=$(pgrep -x firezone-gatewa | paste -sd, -)
    relay_pids=$(pgrep -x firezone-relay | paste -sd, -)

    if [ -z "$client_pids" ] || [ -z "$gateway_pids" ]; then
        echo "ERROR: client/gateway processes not found; is the stack running?" >&2
        exit 1
    fi

    echo "==> Recording perf profiles ($perf_event, client: $client_pids, gateway: $gateway_pids, relay: $relay_pids)"
    # iperf runs for 30s; record a bit longer and let the recorders die with the test.
    perf record -e "$perf_event" -F 4999 --call-graph fp -o "$TEST_NAME-client.perf.data" -p "$client_pids" -- sleep 45 &
    perf_pids+=($!)
    perf record -e "$perf_event" -F 4999 --call-graph fp -o "$TEST_NAME-gateway.perf.data" -p "$gateway_pids" -- sleep 45 &
    perf_pids+=($!)
    if [ "$FLAVOUR" = "relayed" ] && [ -n "$relay_pids" ]; then
        perf record -e "$perf_event" -F 4999 --call-graph fp -o "$TEST_NAME-relay.perf.data" -p "$relay_pids" -- sleep 45 &
        perf_pids+=($!)
    fi
fi

echo "==> Running $FLAVOUR-$TEST"
"./scripts/tests/perf/$TEST.sh"

if ((${#perf_pids[@]} > 0)); then
    kill -INT "${perf_pids[@]}" 2>/dev/null || true
    wait "${perf_pids[@]}" 2>/dev/null || true

    if command -v inferno-collapse-perf >/dev/null 2>&1; then
        for data in "$TEST_NAME"-*.perf.data; do
            perf script -i "$data" | inferno-collapse-perf | inferno-flamegraph >"${data%.perf.data}.svg" 2>/dev/null ||
                echo "WARN: flamegraph generation failed for $data" >&2
        done
    fi
fi

jq '{ throughput_bps: .end.sum_received.bits_per_second, retransmits: (.end.sum_sent.retransmits // -1), lost_percent: (.end.sum.lost_percent // null) }' \
    "$TEST_NAME.json" | tee "$TEST_NAME.summary.json"

echo ""
echo "Results in $RESULTS_DIR/"
