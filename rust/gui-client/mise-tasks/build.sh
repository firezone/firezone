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
    # Moves the debug info into `.debug` files, which only go to Sentry.
    for bin in firezone-gui-client firezone-client-tunnel firezone-cli; do
        objcopy --only-keep-debug "$release/$bin" "$release/$bin.debug"
        objcopy --strip-debug --add-gnu-debuglink="$release/$bin.debug" "$release/$bin"
    done

    packages=("$PWD/$release/firezone-client-gui.deb" "$PWD/$release/firezone-client-gui.rpm")
    cargo deb --package firezone-gui-client --no-build --no-strip --output "${packages[0]}"
    # Only finds the workspace's `target` directory when run from the workspace root.
    (cd .. && cargo generate-rpm --package gui-client/src-tauri --payload-compress gzip --output "${packages[1]}")
    ;;
msys* | cygwin*)
    ../../scripts/build/sign.sh \
        "$release/firezone-gui-client.exe" \
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

    case "$(rustc -vV | sed -n 's/^host: //p')" in
    aarch64-*) arch=arm64 ;;
    *) arch=x64 ;;
    esac
    version=$(cargo pkgid -p firezone-gui-client)
    target_dir=$(cygpath -aw "$release")
    wixobj=$(mktemp -d)
    # Tauri's bundler also ran WiX with only these environment variables.
    wix() { env -i SYSTEMROOT="$SYSTEMROOT" TMP="$TMP" TEMP="$TEMP" "$(command -v "$1")" "${@:2}"; }
    wix candle -nologo -arch "$arch" -ext WixUtilExtension \
        -dVersion="${version##*@}" -dTargetDir="$target_dir" -I"$target_dir" \
        -out "$(cygpath -aw "$wixobj")\\" src-tauri/win_files/*.wxs
    wix light -nologo -ext WixUIExtension -ext WixUtilExtension -cultures:en-us \
        -out "$release/firezone-client-gui.msi" "$wixobj"/*.wixobj
    ../../scripts/build/sign.sh "$release/firezone-client-gui.msi"
    packages=("$release/firezone-client-gui.msi")
    ;;
esac

if [[ -n "${usage_out:-}" ]]; then
    for package in "${packages[@]}"; do
        cp "$package" "$usage_out.${package##*.}"
    done
fi
