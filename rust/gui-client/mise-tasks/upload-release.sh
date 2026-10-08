#!/usr/bin/env bash
#MISE description="Attach the packages copied by `build --out <prefix>` to a GitHub release"
#MISE dir="{{config_root}}"
#USAGE arg "<tag>"
#USAGE arg "<prefix>"
set -euxo pipefail

tag="${usage_tag:?}"
prefix="${usage_prefix:?}"

# The asset names are tied to the update checker in `src-tauri/src/updates.rs`.
case "$OSTYPE" in
linux*) files=("$prefix".{deb,rpm}{,.sha256sum.txt}) ;;
*) files=("$prefix".msi{,.sha256sum.txt}) ;;
esac

# Only clobber existing assets while the release is still a draft.
clobber=()
if [[ "$(gh release view "$tag" --json isDraft --jq .isDraft)" == "true" ]]; then
    clobber=(--clobber)
fi

gh release upload "$tag" "${files[@]}" "${clobber[@]}"
