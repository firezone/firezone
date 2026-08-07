#!/usr/bin/env bash

set -euo pipefail

# Bundle all web assets
pnpm vite build

# Compile Rust and bundle.
#
# `RPM_RELEASE` gives the `.rpm` a per-build release tag. The preview channel
# publishes every build of the same version, so without it each build would
# reuse the NEVRA of the previous one and overwrite it at the same URL, leaving
# clients that still hold the older repodata with a checksum mismatch. Tauri
# defaults the tag to `1` when it is unset, which is what a local build wants.
if [[ -n "${RPM_RELEASE:-}" ]]; then
    # A `-` would corrupt the NEVRA that `scripts/sync-rpm.sh` parses back out of
    # the filename, and anything outside this set could break the JSON below.
    if [[ ! "${RPM_RELEASE}" =~ ^[A-Za-z0-9._]+$ ]]; then
        echo "RPM_RELEASE must match [A-Za-z0-9._]+, got '${RPM_RELEASE}'" >&2
        exit 1
    fi

    pnpm tauri build --config "{\"bundle\":{\"linux\":{\"rpm\":{\"release\":\"${RPM_RELEASE}\"}}}}"
else
    pnpm tauri build
fi
