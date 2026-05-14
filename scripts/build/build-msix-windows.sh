#!/usr/bin/env bash
# Pack the Firezone sparse MSIX manifest into a signed `.msix` and
# place it where the Tauri/WiX bundler picks it up (`target/release/
# firezone.msix`).
#
# Driven from `tauri-pre-bundle-windows.sh`, which the Tauri build
# pipeline invokes via `tauri.windows.conf.json:beforeBundleCommand`.
# Requires:
#
# - MakeAppx.exe in PATH (or under `WIX_PATH`/`WindowsSdkPath`)
# - AzureSignTool configured via `scripts/build/sign.sh`'s env vars.

set -euxo pipefail

# Resolve paths regardless of which cwd Tauri invoked us from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC_TAURI_DIR="$WORKSPACE_ROOT/rust/gui-client/src-tauri"
SIGN_SCRIPT="$SCRIPT_DIR/sign.sh"
TARGET_DIR="$WORKSPACE_ROOT/rust/target/release"
OUTPUT_MSIX="$TARGET_DIR/firezone.msix"
MANIFEST="$SRC_TAURI_DIR/win_files/AppxManifest.xml"

echo "build-msix-windows.sh: PWD=$(pwd)"
echo "build-msix-windows.sh: WORKSPACE_ROOT=$WORKSPACE_ROOT"
echo "build-msix-windows.sh: TARGET_DIR=$TARGET_DIR"
echo "build-msix-windows.sh: TARGET_DIR contents:"
ls -la "$TARGET_DIR" 2>&1 | head -40 || true

# Locate MakeAppx.exe. The Windows SDK is preinstalled on the
# `windows-2022` runner image but isn't on PATH. We can't pin a
# specific SDK build (newer images bring newer SDK versions and the
# old ones aren't necessarily kept) so we glob all installed SDKs and
# pick the highest version that ships an x64 MakeAppx.
MAKEAPPX="${MAKEAPPX:-}"
if [ -z "$MAKEAPPX" ]; then
    if command -v MakeAppx.exe >/dev/null 2>&1; then
        MAKEAPPX="$(command -v MakeAppx.exe)"
    else
        # Find candidates from both x86 and x64 SDK roots, sort
        # version-aware and take the newest.
        mapfile -t CANDIDATES < <(
            find \
                "/c/Program Files (x86)/Windows Kits/10/bin" \
                "/c/Program Files/Windows Kits/10/bin" \
                -maxdepth 3 -type f -iname MakeAppx.exe -path '*/x64/*' 2>/dev/null \
                | sort -V
        )
        if [ "${#CANDIDATES[@]}" -gt 0 ]; then
            MAKEAPPX="${CANDIDATES[-1]}"
        fi
    fi
fi
if [ -z "$MAKEAPPX" ] || [ ! -x "$MAKEAPPX" ]; then
    echo "MakeAppx.exe not found. Set \$MAKEAPPX or install the Windows 10 SDK." >&2
    echo "Searched: PATH and /c/Program Files*/Windows Kits/10/bin/*/x64/MakeAppx.exe" >&2
    exit 1
fi
echo "Using MakeAppx: $MAKEAPPX"

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

# MSYS / Git Bash auto-translates argv elements that look like POSIX
# paths (`/foo`) into Windows paths (`C:\foo`) when invoking native
# Windows binaries. MakeAppx uses `/d`, `/p`, `/nv`, `/o` etc. as
# command-line *flags* — bare `/d` gets translated to `D:` and the
# binary then complains `Unknown command line option: D:/`. The
# escape convention is to prefix the flag with a second `/`; MSYS
# strips it before exec and MakeAppx sees the original flag.
"$MAKEAPPX" pack \
    //d "$STAGING" \
    //p "$OUTPUT_MSIX" \
    //nv \
    //o

if [ -x "$SIGN_SCRIPT" ]; then
    "$SIGN_SCRIPT" "$OUTPUT_MSIX"
fi

echo "Built $OUTPUT_MSIX"
