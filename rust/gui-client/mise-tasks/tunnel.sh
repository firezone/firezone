#!/usr/bin/env bash
#MISE description="Run the Tunnel service interactively for local GUI dev. `--skip-peer-verification` skips the peer check so it accepts a non-installed GUI build; must be run from an elevated shell (Administrator on Windows, root on Unix)."
#MISE raw=true
set -euo pipefail

exec cargo run -p firezone-gui-client --bin firezone-client-tunnel -- run-interactive --skip-peer-verification
