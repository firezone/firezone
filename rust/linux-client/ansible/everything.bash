#!/usr/bin/env bash

set -euo pipefail

export CONNLIB_LOG_UPLOAD_INTERVAL_SECS=300

cargo build --release
ansible-playbook -i ansible/inventory.ini ansible/install-firezone.yaml
ssh -p 3300 user@leyley.local
