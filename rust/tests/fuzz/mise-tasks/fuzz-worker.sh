#!/usr/bin/env bash
#MISE description="Run one AFL++ discovery worker"
#MISE hide=true
#USAGE arg "<target>"
#USAGE arg "<worker>"
#USAGE arg "<seconds>"
#USAGE arg "[afl_args]…" var=#true
set -euo pipefail
cd "$(dirname "$0")/.."
target="${usage_target:?}"
# shellcheck source=../helpers.sh
source ./helpers.sh

export AFL_FUZZER_LOOPCOUNT=1 AFL_NO_UI=1 AFL_SKIP_CPUFREQ=1 AFL_AUTORESUME=1
ulimit -c 0
max_length=4096
if [ "$target" = tunnel-proto ] || [ "$target" = relay-proto ]; then
    max_length=8192
fi
name="worker-${usage_worker:?}"
mode=-S
[ "$usage_worker" -ne 0 ] || mode=-M
output="afl-output/$target"
mkdir -p "$output"
trap 'tail -n 20 "$output/$name.log"' EXIT
eval "set -- ${usage_afl_args:-}"
cargo afl fuzz -i "corpus/$target" -o "$output" "$mode" "$name" \
    -V "${usage_seconds:?}" -G "$max_length" -t 10000 -m none "$@" -- "$afl_binary" "$target" \
    >"$output/$name.log" 2>&1
