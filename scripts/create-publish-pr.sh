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
    echo "No monorepo changes for $component $version; skipping monorepo PR."
else
    git commit -m "chore: bump versions for $component to $version"
    git push -u origin HEAD --force
    gh pr create \
        --title "chore: publish $component $version" \
        --body "" \
        --reviewer @firezone/engineering
fi

# --- Website (firezone/website): changelog + displayed version markers ------
#
# The marketing website and product docs live in the separate firezone/website
# repo (the website was split out of this monorepo). Clone it, apply the
# website-specific bumps, and open a PR there.
#
# Requires FIREZONE_BOT_WEBSITE_TOKEN: a token scoped to firezone/website with
# Contents: write (to push the branch) and Pull requests: write (to open the
# PR). Falls back to GITHUB_TOKEN if that bot already has access.
website_token="${FIREZONE_BOT_WEBSITE_TOKEN:-${GITHUB_TOKEN:-}}"
if [ -z "$website_token" ]; then
    echo "FIREZONE_BOT_WEBSITE_TOKEN or GITHUB_TOKEN must be set to open the website PR" >&2
    exit 1
fi

website_dir=$(mktemp -d)
trap 'rm -rf "$website_dir"' EXIT

git clone --depth 1 \
    "https://x-access-token:${website_token}@github.com/firezone/website.git" \
    "$website_dir"

# Mirror the committer identity (and commit signing, if configured) from this repo.
git -C "$website_dir" config user.email "$(git config user.email)"
git -C "$website_dir" config user.name "$(git config user.name)"
signingkey="$(git config --get user.signingkey || true)"
if [ -n "$signingkey" ]; then
    git -C "$website_dir" config user.signingkey "$signingkey"
    git -C "$website_dir" config commit.gpgsign true
fi

git -C "$website_dir" checkout -b "chore/publish-$component-$version"

WEBSITE_DIR="$website_dir" "$path_to_bump_versions" bump_website

git -C "$website_dir" add -A
if git -C "$website_dir" diff --staged --quiet; then
    echo "No website changes for $component $version; skipping website PR."
else
    git -C "$website_dir" commit -m "chore: update changelog and versions for $component $version"
    git -C "$website_dir" push -u origin HEAD --force
    (cd "$website_dir" && GH_TOKEN="$website_token" gh pr create \
        --title "chore: publish $component $version" \
        --body "")
fi
