#!/usr/bin/env bash
set -xeuo pipefail

component="$1"
version="$2"

path_to_self=$(readlink -f "$0")
scripts_dir=$(dirname "$path_to_self")
path_to_bump_versions="$scripts_dir/bump-versions.sh"

function gateway_checksum_env() {
    local version="$1"
    local name="$2"
    local checksum="${!name:-}"

    if [[ ! "$checksum" =~ ^[0-9a-f]{64}$ ]]; then
        echo "$name must be set to the SHA-256 checksum for gateway $version" >&2
        exit 1
    fi

    printf '%s' "$checksum"
}

function update_gateway_checksums() {
    local version="$1"
    local x86_64_checksum
    local aarch64_checksum
    local armv7_checksum

    x86_64_checksum=$(gateway_checksum_env "$version" GATEWAY_X86_64_SHA256)
    aarch64_checksum=$(gateway_checksum_env "$version" GATEWAY_AARCH64_SHA256)
    armv7_checksum=$(gateway_checksum_env "$version" GATEWAY_ARMV7_SHA256)

    "$path_to_bump_versions" update_gateway_checksums "$version" "$x86_64_checksum" "$aarch64_checksum" "$armv7_checksum"
}

# Create branch
git checkout -b "chore/publish-$component-$version"

# Update version variables in script
"$path_to_bump_versions" update_version_variables "$component" "$version"

if [ "$component" = "gateway" ]; then
    update_gateway_checksums "$version"
fi

# Bump versions across the monorepo (product version markers + Cargo.lock)
"$path_to_bump_versions"

git add -A
if git diff --staged --quiet; then
    echo "No changes for $component $version; skipping PR."
else
    git commit -m "chore: bump versions for $component to $version"
    git push -u origin HEAD --force
    gh pr create \
        --title "chore: publish $component $version" \
        --body "" \
        --reviewer firezone/engineering
fi
