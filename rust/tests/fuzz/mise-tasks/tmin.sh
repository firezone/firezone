#!/usr/bin/env bash
#MISE description="Reduce a crashing input with AFL++"
#MISE depends=["install-afl"]
#MISE raw=true
#USAGE arg "<target>"
#USAGE arg "<testcase>"
set -euo pipefail
cd "$(dirname "$0")/.."
target="${usage_target:?}"
# shellcheck source=rust/tests/fuzz/helpers.sh
source ./helpers.sh
build_afl
AFL_FUZZER_LOOPCOUNT=1 cargo afl tmin -i "${usage_testcase:?}" \
    -o "${usage_testcase}.minimized" -t 10000 -m none -- "$afl_binary"
