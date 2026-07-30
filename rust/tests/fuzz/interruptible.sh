#!/usr/bin/env bash
#
# Runs a command so that Ctrl+C stops it.
#
# libFuzzer's out-of-process modes (`-fork`, `-merge`, `-minimize_crash`) start
# each worker with system(3), which ignores SIGINT in the caller for as long as
# that worker runs. The driver therefore never sees the Ctrl+C: the signal
# reaches only the worker, and the driver starts a replacement for it. The run
# outlives every process that was supervising it and has to be killed by hand.
#
# SIGTERM is not ignored, so translate the interrupt into one of those. Job
# control puts the command in a process group of its own, both so that
# signalling all of it does not also signal us and so that the terminal
# delivers Ctrl+C here rather than straight to the workers.

set -euo pipefail

set -m
"$@" &
child=$!
set +m

trap 'kill -TERM -"$child" 2>/dev/null || true' HUP INT QUIT TERM

# Each trap that runs cuts `wait` short, so keep waiting until the command is
# really gone.
status=0
while :; do
  wait "$child" && status=0 || status=$?
  kill -0 "$child" 2>/dev/null || break
done

exit "$status"
