#!/usr/bin/env bash

set -euo pipefail

resolvectl status
sudo systemctl start firezone-client
sudo systemctl status firezone-client
