#!/usr/bin/env bash

set -euo pipefail

docker compose exec client cat firezone-linux-client > firezone-linux-client
chmod u+x firezone-linux-client

cp scripts/firezone-client.service /etc/systemd/system/
