#!/usr/bin/env bash
set -xeuo pipefail

local component="$1"
local version="$2"

# Create branch
git checkout -b "chore/publish-$component-$version"

# Update version variables in script
scripts/bump-versions.sh update_version_variables $component $version
git add scripts/bump-versions.sh
git commit -m "chore: bump versions for $component to $version"

# Bump versions across the codebase
scripts/bump-versions.sh
git add -A
git commit -m "chore: bump versions for $component"

# Create PR
git push -u origin HEAD --force

gh pr create \
  --title "chore: publish $component $version" \
  --reviewer @firezone/engineering
