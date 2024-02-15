#!/usr/bin/env bash

set -euo pipefail

sudo FIREZONE_DNS_CONTROL=systemd-resolved RUST_LOG=firezone-linux-client=debug,firezone-tunnel=debug,info firezone-linux-client --firezone-id firezone --api-url wss://api.firez.one $(cat "$HOME/firezone-token")
