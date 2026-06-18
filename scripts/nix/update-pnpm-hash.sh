#!/usr/bin/env bash
# Recompute the pnpm-deps hash pinned in
# scripts/nix/packages/firezone-gui-client/frontend.nix.
#
# `fetchPnpmDeps` is a fixed-output derivation, so its hash must change
# whenever rust/gui-client/pnpm-lock.yaml does (e.g. every dependabot bump).
# This script pins a deliberately-wrong hash to force the FOD to rebuild,
# reads the correct value out of Nix's mismatch error, and rewrites the pin in
# place. It exits 0 whether or not a change was needed; run `git diff`
# afterwards to see if the pin moved. CD runs it on a failed Nix build to open
# a corrective PR; you can also run it locally on a Linux host with Nix.
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"
frontend_nix="scripts/nix/packages/firezone-gui-client/frontend.nix"

# A guaranteed-wrong SRI hash (the conventional nixpkgs `lib.fakeHash`) so the
# FOD always rebuilds and reports the real value, regardless of what is pinned
# now or already present in the store.
fake_hash="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

current_hash=$(grep -oE 'sha256-[A-Za-z0-9+/=]{40,}' "$frontend_nix" | head -n1)
if [ -z "$current_hash" ]; then
  echo "Could not find a pnpm-deps hash in $frontend_nix" >&2
  exit 1
fi

sed -i "s|$current_hash|$fake_hash|" "$frontend_nix"

# With the sentinel pinned the FOD fails fast on its hash check, long before
# any Rust compilation, so this build is cheap.
build_log=$(nix build .#firezone-gui-client --no-link --print-build-logs 2>&1 || true)

new_hash=$(printf '%s\n' "$build_log" \
  | grep -oE 'got:[[:space:]]+sha256-[A-Za-z0-9+/=]+' \
  | grep -oE 'sha256-[A-Za-z0-9+/=]+' \
  | tail -n1)

if [ -z "$new_hash" ]; then
  # No mismatch was reported: restore the original pin and assume it was
  # correct (the build failed for some other reason, if it failed at all).
  sed -i "s|$fake_hash|$current_hash|" "$frontend_nix"
  echo "pnpm-deps hash already correct ($current_hash)"
  exit 0
fi

sed -i "s|$fake_hash|$new_hash|" "$frontend_nix"

if [ "$new_hash" = "$current_hash" ]; then
  echo "pnpm-deps hash unchanged ($current_hash)"
else
  echo "pnpm-deps hash updated: $current_hash -> $new_hash"
fi
