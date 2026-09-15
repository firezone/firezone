#!/usr/bin/env bash
#MISE description="Unpack a fuzz target's committed corpus"
#USAGE arg "<target>"
#USAGE arg "[archive]"
set -euo pipefail
cd "$(dirname "$0")/.."

target="${usage_target:?}"
archive="${usage_archive:-corpora/$target.tar.gz}"
corpus="corpus/$target"

# Every task that reads the corpus depends on this one, so a single `grow` run
# reaches it several times. Re-extracting would put back whatever `cmin` had
# just dropped, which is how the committed corpora came to carry inputs the
# merge discards. Once the directory exists it is the working copy; only an
# explicitly named archive overlays onto it.
if [ -z "${usage_archive:-}" ] && [ -d "$corpus" ] && [ -n "$(ls -A "$corpus")" ]; then
    echo "$corpus is already unpacked; leaving it as it is."
    exit 0
fi

if tar -tzf "$archive" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
    echo "error: refusing to unpack unsafe paths from $archive" >&2
    exit 1
fi

mkdir -p "$corpus"
tar -xzf "$archive" --no-same-owner --no-same-permissions -C "$corpus"
