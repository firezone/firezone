#!/usr/bin/env bash
#MISE description="Build the release GUI client and its packages: deb and rpm on Linux, a signed MSI on Windows"
#USAGE flag "--out <prefix>" help="Also copy each package to <prefix>.<ext>, next to its SHA256 sum"
set -euxo pipefail

release=../target/release

pnpm install --frozen-lockfile
pnpm exec vite build

# The `firezone` CLI is its own workspace member, so `tauri build` never compiles it.
cargo build --release -p firezone-cli
pnpm exec tauri build --no-bundle

case "$OSTYPE" in
linux*)
    # Moves the debug info into `.debug` files, which only go to Sentry.
    for bin in firezone-client-gui firezone-client-tunnel firezone-cli register-sparse; do
        objcopy --only-keep-debug "$release/$bin" "$release/$bin.debug"
        objcopy --strip-debug --add-gnu-debuglink="$release/$bin.debug" "$release/$bin"
    done
    packages=(deb rpm)
    ;;
msys* | cygwin*)
    # Tauri signs `Firezone.exe` and the MSI itself, after patching the binary.
    ../../scripts/build/sign.sh \
        "$release/firezone-client-tunnel.exe" \
        "$release/register-sparse.exe" \
        "$release/firezone-cli.exe"
    ../../scripts/build/build-msix-windows.sh
    packages=(msi)
    ;;
esac

pnpm exec tauri bundle

if [[ -n "${usage_out:-}" ]]; then
    for ext in "${packages[@]}"; do
        dest="$usage_out.$ext"
        cp "$release"/bundle/"$ext"/*."$ext" "$dest"
        sha256sum "$dest" >"$dest.sha256sum.txt"
    done
fi
