#!/usr/bin/env bash
#MISE description="Build the bundled AFL++ runtime for the pinned Rust toolchain"
#MISE depends=["install-toolchain"]
set -euo pipefail

# mise caches cargo-afl's binary; its per-toolchain runtime lives separately.
cargo afl config --build 1>&2
