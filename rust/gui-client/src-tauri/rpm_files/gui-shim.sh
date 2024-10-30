#!/usr/bin/env bash
# Installed as `/usr/bin/firezone-client-gui` on RPM systems since we bundle a bunch of libs

set -euo pipefail

LD_LIBRARY_PATH=/usr/lib/dev.firezone.client exec /usr/lib/dev.firezone.client/firezone-client-gui
