#!/usr/bin/env bash
set -e

cargo build --package firezone-relay --bin firezone-relay --example client --example gateway

cleanup() {
    pkill -P $$ || true # Kill all child-processes of the current process.
    docker stop ${redis_container} >/dev/null
}
trap cleanup EXIT

redis_container=$(docker run -d -p 6379:6379 redis:latest)

RED=$(echo -e '\033[0;31m')
GREEN=$(echo -e '\033[0;32m')
BLUE=$(echo -e '\033[0;34m')
NC=$(echo -e '\033[0m')

target_directory=$(cargo metadata --format-version 1 | jq -r '.target_directory')
client="$target_directory/debug/examples/client"
gateway="$target_directory/debug/examples/gateway"
relay="$target_directory/debug/firezone-relay"

export PUBLIC_IP4_ADDR=127.0.0.1
export RNG_SEED=0
export RUST_LOG=firezone_relay=debug

# Client and relay run in the background.
$client 2>&1 | sed "s/^/${RED}[ client]${NC} /" &
$relay 2>&1 | sed "s/^/${GREEN}[  relay]${NC} /" &

$gateway 2>&1 | sed "s/^/${BLUE}[gateway]${NC} /"

exit "${PIPESTATUS[0]}"
