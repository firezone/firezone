#!/usr/bin/env bash

set -euo pipefail

# Used for release artifact
# In release mode the name comes from tauri.conf.json
cp "../target/release/Firezone.exe" "${{ env.BINARY_DEST_PATH }}-x64.exe"
cp "../target/release/bundle/msi/*.msi" "${{ env.BINARY_DEST_PATH }}-x64.msi"
cp "../target/release/firezone_windows_client.pdb" "${{ env.BINARY_DEST_PATH }}-x64.pdb"

Get-FileHash ${{ env.BINARY_DEST_PATH }}-x64.exe -Algorithm SHA256 | Select-Object Hash > ${{ env.BINARY_DEST_PATH }}-x64.exe.sha256sum.txt
Get-FileHash ${{ env.BINARY_DEST_PATH }}-x64.msi -Algorithm SHA256 | Select-Object Hash > ${{ env.BINARY_DEST_PATH }}-x64.msi.sha256sum.txt
Get-FileHash ${{ env.BINARY_DEST_PATH }}-x64.pdb -Algorithm SHA256 | Select-Object Hash > ${{ env.BINARY_DEST_PATH }}-x64.pdb.sha256sum.txt

# This might catch regressions in #3384, depending how CI runners
# handle exit codes
git diff --exit-code
