#!/usr/bin/env bash
set -xeuo pipefail

component="$1"
version="$2"

path_to_self=$(readlink -f "$0")
scripts_dir=$(dirname "$path_to_self")
path_to_bump_versions="$scripts_dir/bump-versions.sh"

# Create branch
git checkout -b "chore/publish-$component-$version"

# Update version variables in script
"$path_to_bump_versions" update_version_variables "$component" "$version"
git add "$path_to_bump_versions"
git commit -m "chore: bump versions for $component to $version"

# Bump versions across the codebase
"$path_to_bump_versions"
git add -A
git commit -m "chore: bump versions for $component"

# Create PR
git push -u origin HEAD --force

gh pr create \
  --title "chore: publish $component $version" \
  --reviewer @firezone/engineering
