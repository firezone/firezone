#!/usr/bin/env bash

set -euo pipefail

docker compose exec client cat firezone-linux-client > /usr/bin/firezone-linux-client
chmod u+x /usr/bin/firezone-linux-client

sudo cp scripts/firezone-client.service /etc/systemd/system/
