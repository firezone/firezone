#!/usr/bin/env bash
# Runs an apt command as root under a wall-clock limit, retrying the whole command.
#
# `Acquire::Retries` cannot rescue a mirror that trickles bytes: apt's own timeout only fires on
# inactivity, so a transfer that never quite stops runs until the step times out and the retry
# never happens. Bounding each attempt is what turns such a stall into a retry.
set -euo pipefail

ATTEMPTS=3
TIMEOUT=120

for ((attempt = 1; attempt <= ATTEMPTS; attempt++)); do
    if sudo timeout --kill-after=10s "$TIMEOUT" "$@"; then
        exit 0
    fi

    echo "::warning::'$*' failed or exceeded ${TIMEOUT}s (attempt ${attempt}/${ATTEMPTS})"
done

echo "::error::'$*' did not succeed within ${ATTEMPTS} attempts"
exit 1
