#!/usr/bin/env bash
#
# Assert that the given containers show no socket errors and no TCP packet
# reordering in their kernel network counters after a perf run.
#
# Counters are read straight from /proc so the same check works everywhere,
# including the iperf3 resource image, which ships no `nstat`. A counter fails
# the check when its name contains "Error" (any protocol, mirroring the previous
# `nstat | grep error`) or is one of the TCP `*Reorder` counters. `TCPOFOQueue`
# is deliberately ignored: it also counts loss-induced gaps and would flake
# whenever a run legitimately retransmits.
#
# Reorder detection is sender-side, so we check every TCP endpoint of the flow;
# the UDP error counters matter on the WireGuard (tunnel) endpoints. Containers
# that aren't running for the current test are skipped.

set -euo pipefail

status=0

for container in "$@"; do
  if [ -z "$(docker compose ps -q "$container")" ]; then
    echo "skipping ${container} (not running)"
    continue
  fi

  # `/proc/net/snmp` and `/proc/net/netstat` share a "header line / value line"
  # layout; `/proc/net/snmp6` (when the netns has IPv6) is a flat "name value"
  # layout. A `---` marker separates the two so one awk pass handles both.
  anomalies=$(
    docker compose exec -T "$container" sh -c \
      'cat /proc/net/snmp /proc/net/netstat; echo ---; cat /proc/net/snmp6 2>/dev/null || true' |
      awk '
        /^---$/ { flat = 1; next }
        !flat {
          if ($1 != hdr) { hdr = $1; delete name; for (i = 2; i <= NF; i++) name[i] = $i; next }
          for (i = 2; i <= NF; i++)
            if ((name[i] ~ /[Ee]rror/ || name[i] ~ /Reorder/) && $i + 0 != 0)
              printf "%s %s = %d\n", $1, name[i], $i
          hdr = ""
          next
        }
        (($1 ~ /[Ee]rror/ || $1 ~ /Reorder/) && $2 + 0 != 0) { printf "%s = %d\n", $1, $2 }
      '
  )

  if [ -n "$anomalies" ]; then
    echo "${container}: socket anomalies detected after perf run:"
    echo "$anomalies" | sed 's/^/    /'
    status=1
  fi
done

exit "$status"
