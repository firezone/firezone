#!/usr/bin/env bash
#MISE description="Run the GUI client in dev against a dev Tunnel service"
#MISE raw=true
set -euo pipefail

exec cargo tauri dev -- -- --skip-peer-verification
