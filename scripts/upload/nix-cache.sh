#!/usr/bin/env bash

# Signs the runtime closures of ./result* with the Firezone Nix cache key
# and syncs them to the `nix` container of the `firezoneartifacts` Azure
# storage account, served at https://artifacts.firezone.dev/nix.
#
# Required environment:
#   NIX_CACHE_SIGNING_KEY                  ed25519 secret key (nix key generate-secret)
#   AZURERM_ARTIFACTS_CONNECTION_STRING    write access to the storage account

set -euo pipefail

staging_dir=$(mktemp -d)

# Sign the full runtime closures so every path in the cache carries our
# signature, including dependencies substituted from cache.nixos.org.
nix store sign --recursive --key-file <(printenv NIX_CACHE_SIGNING_KEY) ./result*

# Nix has no Azure backend, so stage a local binary cache and sync it.
nix copy --to "file://$staging_dir?compression=zstd" ./result*

# Priority below cache.nixos.org (40) so clients prefer upstream for
# shared paths.
printf 'StoreDir: /nix/store\nWantMassQuery: 1\nPriority: 41\n' >"$staging_dir/nix-cache-info"

# Incremental: already-present blobs are skipped. azcopy's
# --delete-destination defaults to false; the cache must never be pruned
# by sync (NARs are shared across releases).
az storage blob sync \
    --container nix \
    --source "$staging_dir" \
    --connection-string "$AZURERM_ARTIFACTS_CONNECTION_STRING"
