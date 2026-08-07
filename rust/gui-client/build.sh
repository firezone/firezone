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
    pnpm tauri build --config "{\"bundle\":{\"linux\":{\"rpm\":{\"release\":\"${RPM_RELEASE}\"}}}}"
else
    pnpm tauri build
fi
