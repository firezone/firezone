#!/usr/bin/env bash
#MISE description="Install the pinned nightly with the components fuzzing needs"
set -euo pipefail

# Status output goes to stderr so tasks that depend on this one can keep a
# machine-readable stdout.
rustup toolchain install "$RUSTUP_TOOLCHAIN" --profile minimal --component rust-src --component llvm-tools-preview 1>&2
