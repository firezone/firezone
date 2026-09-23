#!/usr/bin/env bash
#MISE description="Replay a corpus in one process and report iterations per second"
#MISE depends=["install-toolchain", "unpack-corpus {{usage.target}}"]
#MISE raw=true
#USAGE arg "<target>"
#USAGE flag "--repeat <repeat>" default="1"
set -euo pipefail
cd "$(dirname "$0")/.."
target="${usage_target:?}"
# shellcheck source=../helpers.sh
source ./helpers.sh
build_replay
"$replay_binary" --replay --repeat "${usage_repeat:-1}" "corpus/$target"
