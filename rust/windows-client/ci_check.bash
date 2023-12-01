#!/usr/bin/env bash
# Usage: ./ci_check.bash

# Performs static checks similar to what the Github Actions workflows will do, so errors can be caught before committing.

# ReactorScram uses this in the Git pre-commit hook on her Windows dev system.

# Fail on any non-zero return code
set -euo pipefail

# Fail on Rust errors
pushd .. > /dev/null
cargo clippy --all-targets --all-features -p firezone-windows-client -- -D warnings
cargo fmt --check
cargo doc --all-features --no-deps --document-private-items -p firezone-windows-client
popd > /dev/null

# Fail on yaml workflow errors
yamllint ../../.github/workflows/*
