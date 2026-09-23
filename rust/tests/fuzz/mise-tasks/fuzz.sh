#!/usr/bin/env bash
#MISE description="Discover coverage with AFL++; extra args are passed to each worker"
#MISE depends=["install-afl", "unpack-corpus {{usage.target}}"]
#MISE raw=true
#USAGE arg "<target>"
#USAGE flag "--workers <workers>" default="1"
#USAGE flag "--seconds <seconds>" default="60"
#USAGE arg "[afl_args]…" var=#true
set -euo pipefail
cd "$(dirname "$0")/.."

target="${usage_target:?}"
# shellcheck source=rust/tests/fuzz/helpers.sh
source ./helpers.sh
workers="${usage_workers:-1}"
seconds="${usage_seconds:-60}"
[[ "$workers" =~ ^[1-9][0-9]*$ && "$seconds" =~ ^[1-9][0-9]*$ ]] || {
    echo "workers and seconds must be positive integers" >&2
    exit 1
}
eval "set -- ${usage_afl_args:-}"
build_afl

# Every discovery input starts from the forkserver's memory snapshot. Replay
# uses an ordinary in-process loop because it does not select inputs by coverage.
export AFL_FUZZER_LOOPCOUNT=1 AFL_NO_UI=1 AFL_SKIP_CPUFREQ=1
ulimit -c 0
max_length=4096
if [ "$target" = tunnel-proto ] || [ "$target" = relay-proto ]; then
    max_length=8192
fi
output="afl-output/$target"
mkdir -p "$output"
pids=()
# shellcheck disable=SC2317
cleanup() {
    trap - EXIT INT TERM HUP
    for pid in "${pids[@]}"; do kill -TERM -- "-$pid" 2>/dev/null || true; done
    for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
    collect_findings all
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# Separate process groups let cancellation stop cargo-afl and all its children.
set -m
for ((worker = 0; worker < workers; worker++)); do
    name="worker-$worker"
    mode=-S
    [ "$worker" -ne 0 ] || mode=-M
    input="corpus/$target"
    # Resume a previous campaign without discarding queues or crash artifacts.
    [ ! -d "$output/$name/queue" ] || input=-
    cargo afl fuzz -i "$input" -o "$output" "$mode" "$name" \
        -V "$seconds" -G "$max_length" -t 10000 -m none "$@" -- "$afl_binary" \
        >"$output/$name.log" 2>&1 &
    pids+=("$!")
done
set +m
status=0
for pid in "${pids[@]}"; do wait "$pid" || status=$?; done
for ((worker = 0; worker < workers; worker++)); do
    tail -n 20 "$output/worker-$worker.log"
done
exit "$status"
