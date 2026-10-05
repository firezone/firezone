#!/usr/bin/env bash
# Recompute the pnpm-deps hash pinned in
# scripts/nix/packages/firezone-gui-client/frontend.nix.
#
# `fetchPnpmDeps` is a fixed-output derivation, so its hash must change
# whenever rust/gui-client/pnpm-lock.yaml does (e.g. every dependabot bump).
# This script pins a deliberately-wrong hash to force the FOD to rebuild,
# reads the correct value out of Nix's mismatch error, and rewrites the pin in
# place. With --check, it restores the file and fails if the pin is stale.
# Run on a Linux host with Nix. Only the dependency fetch is built.
set -euo pipefail

check=false
case "${1:-}" in
  --check) check=true ;;
  "") ;;
  *) echo "Usage: $0 [--check]" >&2; exit 1 ;;
esac

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

# Restore on every failure (including interrupted builds), and always in check
# mode. Preserve the exact original file, not just the hash.
original=$(mktemp)
cp "$frontend_nix" "$original"
restore=true
cleanup() {
  if "$restore"; then
    cp "$original" "$frontend_nix"
  fi
  rm -f "$original"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

sed "s|$current_hash|$fake_hash|" "$original" > "$frontend_nix"

# Bypass substitution of the pinned output and fetch just the pnpm store.
# The fake hash must produce a mismatch; any other failure is an error.
system=$(nix eval --impure --raw --expr builtins.currentSystem)
build_log=$(nix build ".#checks.${system}.pnpm-deps" --no-link --print-build-logs 2>&1 || true)
new_hash=$(printf '%s\n' "$build_log" \
  | sed -nE 's/^[[:space:]]*got:[[:space:]]+(sha256-[A-Za-z0-9+/=]+)[[:space:]]*$/\1/p' \
  | tail -n1)

if [ -z "$new_hash" ]; then
  printf '%s\n' "$build_log" >&2
  echo "Could not determine the pnpm-deps hash; validation failed." >&2
  exit 1
fi

if [ "$new_hash" = "$current_hash" ]; then
  echo "pnpm-deps hash correct ($current_hash)"
elif "$check"; then
  echo "pnpm-deps hash is stale: $current_hash -> $new_hash" >&2
  echo "Merge the pnpm hash bump PR (chore/nix-pnpm-hash), then retry the release from the corrected commit." >&2
  echo "Open PR: https://github.com/${GITHUB_REPOSITORY:-firezone/firezone}/pulls?q=is%3Apr+is%3Aopen+head%3Achore%2Fnix-pnpm-hash" >&2
  echo "If no PR exists, run scripts/nix/update-pnpm-hash.sh on Linux and commit the updated pin." >&2
  exit 1
else
  sed "s|$current_hash|$new_hash|" "$original" > "$frontend_nix"
  restore=false
  echo "pnpm-deps hash updated: $current_hash -> $new_hash"
fi
