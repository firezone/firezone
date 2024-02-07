#!/usr/bin/env bash

set -euo pipefail

cargo build --release
ansible-playbook -i ansible/inventory.ini ansible/install-firezone.yaml
ssh -p 3300 user@leyley.local
