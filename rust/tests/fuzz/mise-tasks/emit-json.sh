#!/usr/bin/env bash
#MISE description="Replay a target's corpus and write it as JSON Lines for the query task"
#MISE depends=["unpack-corpus {{usage.target}}"]
#USAGE arg "<target>"
set -euo pipefail
cd "$(dirname "$0")/.."
target="${usage_target:?}"
# shellcheck source=../helpers.sh
source ./helpers.sh
build_replay
rm -rf "json/$target"
"$replay_binary" "$target" --replay "corpus/$target" --emit-json "json/$target"
