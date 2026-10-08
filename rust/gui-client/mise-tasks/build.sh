#!/usr/bin/env bash
#MISE description="Build the release GUI client and its packages: deb and rpm on Linux, a signed MSI on Windows"
#MISE dir="{{config_root}}"
#USAGE flag "--out <prefix>" help="Also copy each package to <prefix>.<ext>, next to its SHA256 sum"
set -euxo pipefail

release=../target/release

# On Windows, mise hands Git Bash a `PATH` that is only partially converted to
# Windows form, and native programs inherit it verbatim until it changes.
if [[ "$OSTYPE" == msys || "$OSTYPE" == cygwin ]]; then
    export PATH="/usr/bin:$PATH"
fi

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

    # The sparse MSIX that gives the app its package identity, picked up by WiX.
    makeappx=$(find "/c/Program Files (x86)/Windows Kits/10/bin" -maxdepth 3 -iname MakeAppx.exe -path "*/x64/*" | sort -V | tail -n 1)
    staging=$(mktemp -d)
    mkdir "$staging/Assets"
    cp src-tauri/win_files/AppxManifest.xml "$staging/"
    for logo in StoreLogo Square150x150Logo Square44x44Logo; do
        cp src-tauri/icons/icon.png "$staging/Assets/$logo.png"
    done
    # The doubled slashes stop Git Bash from rewriting the flags as paths.
    "$makeappx" pack //d "$staging" //p "$release/firezone.msix" //nv //o
    ../../scripts/build/sign.sh "$release/firezone.msix"
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
