#!/usr/bin/env bash

set -euo pipefail

sudo RUST_LOG=firezone-linux-client=debug,info ./firezone-linux-client --firezone-id firezone --api-url wss://api.firez.one $(cat "$HOME/firezone-token")
