#!/usr/bin/env bash
#MISE description="Run the GUI client for rapid UI iteration with an in-process mock Tunnel service (--mock-tunnel) and the portal decoupled (--skip-portal-auth). Self-contained: no root, no separate process."
#MISE raw=true
set -euo pipefail

exec cargo tauri dev -- -- --skip-portal-auth --mock-tunnel
