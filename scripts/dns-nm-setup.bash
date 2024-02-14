#!/usr/bin/env bash

set -euo pipefail

nslookup github.com
sudo apt-get install -y network-manager
nslookup github.com
