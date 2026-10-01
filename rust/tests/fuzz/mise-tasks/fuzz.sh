#!/usr/bin/env bash
#MISE description="Discover coverage with AFL++; extra args are passed to each worker"
#MISE depends=["unpack-corpus {{usage.target}}"]
#MISE raw=true
#USAGE arg "<target>"
#USAGE flag "--workers <workers>" default="1"
#USAGE flag "--seconds <seconds>" default="60"
#USAGE arg "[afl_args]…" var=#true
set -euo pipefail
cd "$(dirname "$0")/.."

target="${usage_target:?}"
# shellcheck source=../helpers.sh
source ./helpers.sh
workers="${usage_workers:-1}"
seconds="${usage_seconds:-60}"
[[ "$workers" =~ ^[1-9][0-9]*$ && "$seconds" =~ ^[1-9][0-9]*$ ]] || {
    echo "workers and seconds must be positive integers" >&2
    exit 1
}
eval "set -- ${usage_afl_args:-}"
build_afl

trap 'collect_findings all' EXIT
tasks=()
for ((worker = 0; worker < workers; worker++)); do
    [ "$worker" -eq 0 ] || tasks+=(:::)
    tasks+=(//rust/tests/fuzz:fuzz-worker "$target" "$worker" "$seconds" "$@")
done
mise run --jobs "$workers" "${tasks[@]}"
