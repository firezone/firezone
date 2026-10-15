#!/usr/bin/env bash
#
# Runs connlib's per-packet bench in a Bencher Bare Metal job and writes the latency per packet to
# /tmp/bmf.json in Bencher Metric Format.

set -euo pipefail

# The job's VM brings up no network interfaces, and its socket buffer limits are too small for the
# event loop to keep up without dropping packets.
ip link set lo up
echo 16777216 >/proc/sys/net/core/rmem_max
echo 16777216 >/proc/sys/net/core/wmem_max

per_packet --bench | tee /tmp/divan.txt

# Divan prints a tree of benchmarks, each followed by a line of throughput in items (packets) per
# second: fastest, slowest, median and mean.
awk '
    match($0, /(├|╰)─ [^ ]+/) {
        prefix = substr($0, 1, RSTART - 1)
        depth = gsub(/│  |   /, "", prefix)
        path[depth] = substr($0, RSTART, RLENGTH)
        sub(/^(├|╰)─ /, "", path[depth])
        name = path[0]
        for (i = 1; i <= depth; i++) name = name "::" path[i]
        next
    }
    /item\/s/ {
        n = 0
        rest = $0
        while (match(rest, /[0-9.]+ [KMG]?item\/s/)) {
            ns[++n] = ns_per_item(substr(rest, RSTART, RLENGTH))
            rest = substr(rest, RSTART + RLENGTH)
        }
        printf "%s\n  \"%s\": { \"latency\": { \"value\": %.2f, \"lower_value\": %.2f, \"upper_value\": %.2f } }", (count++ ? "," : "{"), name, ns[3], ns[1], ns[2]
    }
    function ns_per_item(rate, scale) {
        scale = rate ~ /Gitem/ ? 1e9 : rate ~ /Mitem/ ? 1e6 : rate ~ /Kitem/ ? 1e3 : 1
        return 1e9 / (rate * scale)
    }
    END {
        if (!count) exit 1
        print "\n}"
    }
' /tmp/divan.txt >/tmp/bmf.json
