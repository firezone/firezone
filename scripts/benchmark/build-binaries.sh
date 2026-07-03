#!/usr/bin/env bash

# Builds release binaries (with debug info + frame pointers for profiling) and
# copies them into rust/ where the benchmark image build (compose.bench.yml)
# picks them up. Mirrors how CI builds the `perf/*` images.
#
# Usage: build-binaries.sh [PACKAGE...]
#        (default: firezone-headless-client firezone-gateway firezone-relay)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TARGET="x86_64-unknown-linux-musl"
if [ $# -eq 0 ]; then
    PACKAGES=(firezone-headless-client firezone-gateway firezone-relay)
else
    PACKAGES=("$@")
fi

cd "$REPO_ROOT/rust"

build=()
for package in "${PACKAGES[@]}"; do
    if [ "$package" = "firezone-relay" ] && ! command -v bpf-linker >/dev/null 2>&1 && ! mise which bpf-linker >/dev/null 2>&1; then
        echo "WARN: bpf-linker not available; using the relay binary from the CI debug image instead" >&2
        container=$(docker create "${BENCH_BASE_RELAY:-ghcr.io/firezone/debug/relay:main}")
        docker cp "$container:/bin/firezone-relay" firezone-relay
        docker rm "$container" >/dev/null
        continue
    fi
    build+=("$package")
done

if ((${#build[@]} > 0)); then
    pkg_args=()
    for package in "${build[@]}"; do
        pkg_args+=(-p "$package")
    done

    # Frame pointers give perf usable call stacks; line-tables-only keeps
    # symbolication working without full debug-info bloat.
    RUSTFLAGS="--cfg tokio_unstable -C force-frame-pointers=yes" \
        CARGO_PROFILE_RELEASE_DEBUG=line-tables-only \
        cargo build --release --target "$TARGET" "${pkg_args[@]}"

    for package in "${build[@]}"; do
        cp "target/$TARGET/release/$package" "$package"
    done
fi

echo "Binaries ready in rust/: ${PACKAGES[*]}"
