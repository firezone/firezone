#!/usr/bin/env bash
#MISE description="Build the bundled AFL++ runtime for the pinned Rust toolchain"
#MISE depends=["install-toolchain"]
set -euo pipefail

# cargo-afl checks the current toolchain's runtime before invoking afl-cmin.
# This also verifies the tools exist when mise restored only cargo-afl itself.
if cargo afl cmin -h >/dev/null 2>&1; then
    exit 0
fi

# A cached executable can refer to bundled sources from a different install
# machine. Reinstall through mise so those sources and the runtime are restored.
mise --cd "$(dirname "$0")/.." install --force cargo:cargo-afl 1>&2
cargo afl cmin -h >/dev/null
