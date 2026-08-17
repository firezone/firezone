#!/usr/bin/env bash
#MISE description="Unpack a fuzz target's committed corpus"
#MISE raw=true
#USAGE arg "<target>"
set -euo pipefail
cd "$(dirname "$0")/.."

target="${usage_target:?}"
archive="corpora/$target.tar.gz"
corpus="corpus/$target"

if tar -tzf "$archive" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
    echo "error: refusing to unpack unsafe paths from $archive" >&2
    exit 1
fi

mkdir -p "$corpus"
tar -xzf "$archive" --no-same-owner --no-same-permissions -C "$corpus"
