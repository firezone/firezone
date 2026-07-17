#!/usr/bin/env bash

source "./scripts/tests/lib.sh"

# Establish a tunnel so there is an active WireGuard session to idle on.
client_ping download.httpbin

# Sum how often the client's threads have been scheduled off-CPU. Every
# wake -> work -> block cycle bumps a `*_ctxt_switches` counter; summed across
# all threads (`/proc/1` is our process) this proxies "how often were we woken".
scheduled_count() {
    # `|| true` so a thread exiting mid-read doesn't trip `pipefail`.
    client sh -c 'cat /proc/1/task/*/status 2>/dev/null || true' |
        awk '/_ctxt_switches:/ { sum += $2 } END { print sum + 0 }'
}

# Diagnostic run: sample several consecutive windows so the CI log shows when the
# iceless path-agent probes settle and what the settled idle rate is. Once
# calibrated this collapses to a single settle `sleep` plus an `assert_lteq`.
prev=$(scheduled_count)
for i in $(seq 1 6); do
    sleep 5
    now=$(scheduled_count)
    echo "idle-window ${i}: scheduled $((now - prev)) times in 5s"
    prev=$now
done
