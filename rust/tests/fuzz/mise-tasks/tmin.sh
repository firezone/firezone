#!/usr/bin/env bash
#MISE description="Reduce a crashing input with AFL++"
#MISE raw=true
#USAGE arg "<target>"
#USAGE arg "<testcase>"
set -euo pipefail
cd "$(dirname "$0")/.."
target="${usage_target:?}"
# shellcheck source=../helpers.sh
source ./helpers.sh
build_afl
# Standalone AFL++ tools do not detect the target's deferred-forkserver marker.
__AFL_DEFER_FORKSRV=1 AFL_FUZZER_LOOPCOUNT=1 \
    cargo afl tmin -i "${usage_testcase:?}" -o "${usage_testcase}.minimized" \
        -t 10000 -m none -- "$afl_binary" "$target"
