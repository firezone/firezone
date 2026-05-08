#!/usr/bin/env bash
# Pack the Firezone sparse MSIX manifest into a signed `.msix` and
# place it where the Tauri/WiX bundler will pick it up
# (`../../firezone.msix` relative to `win_files/`).
#
# Run from the Tauri build pipeline via
# `tauri.windows.conf.json:beforeBundleCommand`. Requires:
#
# - MakeAppx.exe in PATH (or under `WIX_PATH`/`WindowsSdkPath`)
# - AzureSignTool configured via `scripts/build/sign.sh`'s env vars.

set -euo pipefail

# Resolve paths regardless of which cwd Tauri invoked us from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_TAURI_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_ROOT="$(cd "$SRC_TAURI_DIR/../../.." && pwd)"
SIGN_SCRIPT="$WORKSPACE_ROOT/scripts/build/sign.sh"
TARGET_DIR="$WORKSPACE_ROOT/rust/target/release"
OUTPUT_MSIX="$TARGET_DIR/firezone.msix"
MANIFEST="$SCRIPT_DIR/AppxManifest.xml"

# Locate MakeAppx.exe. The Tauri Windows runner has the Windows SDK on
# PATH, but the Visual Studio installer puts it under varying paths.
MAKEAPPX="${MAKEAPPX:-}"
if [ -z "$MAKEAPPX" ]; then
    if command -v MakeAppx.exe >/dev/null 2>&1; then
        MAKEAPPX="$(command -v MakeAppx.exe)"
    else
        # Fall back to the WixToolset bundle of MakeAppx.
        for c in \
            "/c/Program Files (x86)/Windows Kits/10/bin/x64/MakeAppx.exe" \
            "/c/Program Files (x86)/Windows Kits/10/bin/10.0.22621.0/x64/MakeAppx.exe" \
            "/c/Program Files (x86)/Windows Kits/10/bin/10.0.19041.0/x64/MakeAppx.exe"; do
            if [ -x "$c" ]; then
                MAKEAPPX="$c"
                break
            fi
        done
    fi
fi
if [ -z "$MAKEAPPX" ] || [ ! -x "$MAKEAPPX" ]; then
    echo "MakeAppx.exe not found. Set \$MAKEAPPX or install the Windows 10 SDK." >&2
    exit 1
fi

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

cp "$MANIFEST" "$STAGING/AppxManifest.xml"
mkdir -p "$STAGING/Assets"

# MSIX manifests reference `Assets\Square*Logo.png` etc.; reuse the
# Tauri icon for all visual elements rather than maintaining a parallel
# image set. The icons are packaged but never displayed — Firezone is
# `AppListEntry="none"`, so the Start menu / app list never sees them.
ICON_SRC="$SRC_TAURI_DIR/icons/icon.png"
for size in StoreLogo Square150x150Logo Square44x44Logo; do
    cp "$ICON_SRC" "$STAGING/Assets/${size}.png"
done

"$MAKEAPPX" pack \
    /d "$STAGING" \
    /p "$OUTPUT_MSIX" \
    /nv \
    /o

if [ -x "$SIGN_SCRIPT" ]; then
    "$SIGN_SCRIPT" "$OUTPUT_MSIX"
fi

echo "Built $OUTPUT_MSIX"
