#!/usr/bin/env bash
#MISE description="Build the release GUI client and its packages: deb and rpm on Linux, a signed MSI on Windows"
#MISE dir="{{config_root}}"
#USAGE flag "--out <prefix>" help="Also copy each package to <prefix>.<ext>"
set -euxo pipefail

release=../target/release

# On Windows, mise hands Git Bash a `PATH` that is only partially converted to
# Windows form, and native programs inherit it verbatim until it changes.
if [[ "$OSTYPE" == msys || "$OSTYPE" == cygwin ]]; then
    export PATH="/usr/bin:$PATH"
fi

pnpm install --frozen-lockfile
pnpm exec vite build

# `tauri/custom-protocol` embeds the frontend built above. Without it, the app
# loads the Vite dev server instead.
cargo build --release -p firezone-gui-client --features tauri/custom-protocol
cargo build --release -p firezone-cli

case "$OSTYPE" in
linux*)
    # `tauri bundle` expects the binary under its `mainBinaryName`.
    cp "$release/firezone-gui-client" "$release/firezone-client-gui"

    # Moves the debug info into `.debug` files, which only go to Sentry.
    for bin in firezone-client-gui firezone-client-tunnel firezone-cli register-sparse; do
        objcopy --only-keep-debug "$release/$bin" "$release/$bin.debug"
        objcopy --strip-debug --add-gnu-debuglink="$release/$bin.debug" "$release/$bin"
    done
    packages=(deb rpm)
    ;;
msys* | cygwin*)
    cp "$release/firezone-gui-client.exe" "$release/Firezone.exe"

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
        cp "$release"/bundle/"$ext"/*."$ext" "$usage_out.$ext"
    done
fi
