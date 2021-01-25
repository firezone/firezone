#!/usr/bin/env zsh
set -e

# Generates 10 WireGuard keypairs for use in Dev/Test environments.
# Do not use in Prod.
repeat 10 {
  key=$(wg genkey | tee >(wg pubkey))
  parts=("${(f)key}")
  echo $parts
}
