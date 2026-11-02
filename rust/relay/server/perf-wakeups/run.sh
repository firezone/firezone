#!/usr/bin/env bash
# Usage (as root, from rust/): relay/server/perf-wakeups/run.sh [reps] [secs] [full|headroom]
set -euo pipefail

REPS=${1:-5}
SECS=${2:-5}
SET=${3:-full}
OUT=$(mktemp)

run() {
    for _ in $(seq "$REPS"); do
        env BENCH_SECS="$SECS" "$@" cargo test -q -p firezone-relay --lib bench::perf_wakeups -- --ignored --nocapture 2>/dev/null |
            grep '^RESULT' >>"$OUT"
    done
}

cargo test -q -p firezone-relay --lib --no-run 2>/dev/null

if [ "$SET" = headroom ]; then
    # Leave one CPU to the readers and skip the OTel record per event.
    for pages in 64 512; do
        for n in 16 64 256 1024 4096; do
            run BENCH_THREADS=3 BENCH_RECORD=0 BENCH_PER_PACKET=1 BENCH_WAKEUP_EVENTS="$n" BENCH_PAGES="$pages"
        done
    done
    run BENCH_THREADS=3 BENCH_RECORD=0 BENCH_PER_PACKET=0
    run BENCH_THREADS=3 BENCH_RECORD=0 BENCH_PER_PACKET=2 BENCH_RING_MIB=16
else
run BENCH_PER_PACKET=0
for n in 1 16 64 256 1024 4096; do
    run BENCH_PER_PACKET=1 BENCH_WAKEUP_EVENTS="$n"
done
run BENCH_PER_PACKET=1 BENCH_WAKEUP_EVENTS=256 BENCH_PAGES=512
for ms in 10 100; do
    run BENCH_PER_PACKET=0 BENCH_READER=timer BENCH_DRAIN_MS="$ms"
    run BENCH_PER_PACKET=1 BENCH_READER=timer BENCH_DRAIN_MS="$ms"
    run BENCH_PER_PACKET=1 BENCH_READER=timer BENCH_DRAIN_MS="$ms" BENCH_PAGES=512
done
for mib in 4 16; do
    run BENCH_PER_PACKET=2 BENCH_RING_MIB="$mib"
done
fi

python3 - "$OUT" <<'PY'
import statistics, sys
from collections import OrderedDict

groups = OrderedDict()
for line in open(sys.argv[1]):
    kv = dict(f.split("=", 1) for f in line.split()[1:])
    key = (kv["cpus"], kv["variant"], kv["reader"], kv["drain_ms"] if kv["reader"] == "timer" else "-",
           kv["wakeup_events"] if kv["variant"] == "per-packet" and kv["reader"] == "epoll" else "-",
           str(int(kv["pages"]) * 4) + "K" if kv["variant"] == "per-packet" else "-")
    groups.setdefault(key, []).append(kv)

cols = ["threads", "variant", "reader", "drain_ms", "wakeup", "buf/cpu", "Mpps", "ns/pkt", "events read", "lost", "missing", "lost %", "max lost/drain", "reader cpu ms"]
rows = []
for key, runs in groups.items():
    med = lambda f: statistics.median(float(r[f]) for r in runs)
    relayed = med("relayed")
    read = med("sizes_read") if key[1] != "baseline" else med("stats_read")
    lost = med("sizes_lost") + med("stats_lost")
    missing = med("sizes_missing")
    rows.append(list(key) + [
        f"{med('pps') / 1e6:.2f}", f"{med('ns_per_packet'):.0f}", f"{read:.0f}", f"{lost:.0f}", f"{missing:.0f}",
        f"{100 * (lost + missing) / relayed:.1f}" if key[1] != "baseline" else "-",
        f"{med('max_lost_per_drain'):.0f}", f"{med('reader_cpu_ms'):.0f}",
    ])

widths = [max(len(c), *(len(r[i]) for r in rows)) for i, c in enumerate(cols)]
fmt = lambda r: "| " + " | ".join(v.ljust(w) for v, w in zip(r, widths)) + " |"
print(fmt(cols))
print("| " + " | ".join("-" * w for w in widths) + " |")
for r in rows:
    print(fmt(r))
PY
echo "raw results: $OUT"
