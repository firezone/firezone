#!/usr/bin/env bash

# Signs the runtime closures of the built out-links with the Firezone Nix cache
# key and syncs them to the `firezoneartifacts` Azure storage account, served at
# https://artifacts.firezone.dev.
#
# Two caches, because they have opposite retention needs:
#   nix     the packages, consumed by anyone installing Firezone from the flake.
#           Pinned release tags must keep resolving, so it is never pruned.
#   nix-ci  the compiled Cargo dependency snapshots CI substitutes instead of
#           recompiling. Nothing outside CI reads them and a snapshot stops
#           being reachable as soon as Cargo.lock or a workspace manifest
#           changes, so a lifecycle rule expires them (see the azure-cdn
#           Terraform workspace).
#
# Required environment:
#   NIX_CACHE_SIGNING_KEY    ed25519 secret key (nix key generate-secret)
#
# Azure auth comes from a prior `azure/login` (OIDC); the commands below use
# --auth-mode login against the firezoneartifacts account.

set -euo pipefail

max_sync_attempts=3

# Drops every path cache.nixos.org already serves. Besides keeping our caches to
# what only we can provide, this is what makes expiring `nix-ci` by last access
# safe: we publish at priority 41, so for a path upstream also has, clients read
# our .narinfo but fetch the NAR from upstream. That .narinfo would stay warm
# while its NAR went cold and got swept, leaving a dangling entry that fails
# builds outright. Dropping both here means it never enters the cache at all.
drop_upstream_paths() {
    local staging_dir="$1"

    # shellcheck disable=SC2016 # the inner script must expand in the child, not here
    find "$staging_dir" -maxdepth 1 -name '*.narinfo' -print0 |
        xargs -0 -r -P 16 -I{} bash -c '
            narinfo="$1"
            hash=$(basename "$narinfo" .narinfo)
            if curl --silent --fail --head --max-time 30 \
                --output /dev/null "https://cache.nixos.org/${hash}.narinfo"; then
                nar=$(awk "/^URL: /{print \$2}" "$narinfo")
                rm -f "$narinfo" "$(dirname "$narinfo")/${nar}"
            fi
        ' _ {}
}

publish() {
    local container="$1"
    shift

    local staging_dir
    staging_dir=$(mktemp -d)

    # Nix has no Azure backend, so stage a local binary cache and sync it.
    nix copy --to "file://$staging_dir?compression=zstd" "$@"

    drop_upstream_paths "$staging_dir"

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
    # the other arch's matrix job. Both caches are content-addressed and shared
    # across releases, so neither may be pruned by sync.
    local attempt
    for ((attempt = 1; attempt <= max_sync_attempts; attempt++)); do
        if az storage blob sync \
            --account-name firezoneartifacts \
            --auth-mode login \
            --container "$container" \
            --source "$staging_dir" \
            --delete-destination false \
            -- \
            --compare-hash=MD5; then
            return 0
        fi

        if ((attempt == max_sync_attempts)); then
            printf 'Sync to %s failed after %d attempts.\n' "$container" "$max_sync_attempts" >&2
            exit 1
        fi

        printf 'Sync to %s attempt %d failed; retrying.\n' "$container" "$attempt" >&2
        sleep $((attempt * 5))
    done
}

# Sign the full runtime closures so every path in the caches carries our
# signature.
nix store sign --recursive --key-file <(printenv NIX_CACHE_SIGNING_KEY) \
    ./result ./result-cargo-artifacts

publish nix ./result
publish nix-ci ./result-cargo-artifacts
