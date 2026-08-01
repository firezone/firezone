#!/usr/bin/env bash

# Signs the runtime closures of ./result* with the Firezone Nix cache key
# and syncs them to the `nix` container of the `firezoneartifacts` Azure
# storage account, served at https://artifacts.firezone.dev/nix.
#
# Required environment:
#   NIX_CACHE_SIGNING_KEY    ed25519 secret key (nix key generate-secret)
#
# Azure auth comes from a prior `azure/login` (OIDC); the commands below use
# --auth-mode login against the firezoneartifacts account.

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

# Compare contents instead of mtimes: this staging directory is freshly
# created, so AzCopy's default mtime comparison would re-upload the entire
# closure on every run. Existing blobs without MD5 metadata are uploaded once
# to seed it. Concurrent matrix jobs can still race on those initial uploads,
# so retry the sync to re-enumerate the destination after the winner finishes.
#
# `az storage blob sync` defaults --delete-destination to true, which would
# prune every NAR not in this single-closure staging dir: prior releases and
# the other arch's matrix job. The cache is content-addressed and shared across
# releases, so it must never be pruned by sync.
max_sync_attempts=3

for ((attempt = 1; attempt <= max_sync_attempts; attempt++)); do
    if az storage blob sync \
        --account-name firezoneartifacts \
        --auth-mode login \
        --container nix \
        --source "$staging_dir" \
        --delete-destination false \
        -- \
        --compare-hash=MD5; then
        break
    fi

    if ((attempt == max_sync_attempts)); then
        printf 'Nix cache sync failed after %d attempts.\n' "$max_sync_attempts" >&2
        exit 1
    fi

    printf 'Nix cache sync attempt %d failed; retrying.\n' "$attempt" >&2
    sleep $((attempt * 5))
done
