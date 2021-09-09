#!/usr/bin/env zsh
set -e

# Generates 10 WireGuard keypairs for use in Dev/Test environments.
repeat 10 {
  key=$(wg genkey | tee >(wg pubkey))
  parts=("${(f)key}")
  echo $parts
}
