#!/usr/bin/env bash

# Run from `rust/linux-client`. Builds the client and uses Ansible to set it up on
# ReactorScram's VM, and install `systemd-resolved`. Doesn't work in CI or anything.
#
# If Ansible succeeds, logs in to the VM via SSH.

set -euo pipefail

export CONNLIB_LOG_UPLOAD_INTERVAL_SECS=300

cargo build --release
ansible-playbook -i ansible/inventory.ini ansible/with-systemd.yaml
ssh -p 3300 user@leyley.local
