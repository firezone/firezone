#!/usr/bin/env python3
"""Runs a past commit's tunnel-bench and derives the Bencher measures around it.

usage: backfill.py <tunnel-bench> <output.json>

Older binaries only print criterion's wall time, so this samples each thread's CPU time from
/proc while criterion collects a benchmark's samples and writes the same Bencher Metric Format
the current harness does: throughput in bits/s and each stage's CPU time in ns/packet.
"""

import glob
import json
import os
import pty
import re
import subprocess
import sys
import tempfile
import threading
import time

PACKET_SIZE = 1280
CLK_TCK = os.sysconf("SC_CLK_TCK")

# Criterion derives the sample directory from the benchmark id, so the id is read back from
# the benchmark.json next to the samples instead.
BENCHMARK_ID = re.compile(
    r"^event_loop/(client_outbound|gateway_inbound|gateway_outbound|client_inbound)/(cidr|dns)"
    r"(?:/udp/flow_logs)?$"
)
PROGRESS = re.compile(r"^Benchmarking (?P<id>\S+): (?P<phase>Collecting|Analyzing)")
ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")

# Measure slug and thread name prefix of each stage. `tun-write` in older harnesses is a
# stand-in for the TUN device, not connlib's TUN thread, so the prefix is case-sensitive.
STAGES = [("event-loop", "event-loop"), ("udp", "UDP"), ("crypto", "wg-"), ("tun", "TUN")]


class ThreadCpu:
    """The latest CPU time in clock ticks of every thread the process has had, by thread id.

    Polled in the background so that a thread exiting between two snapshots still contributes
    the time it used up to its last poll.
    """

    def __init__(self, pid):
        self.pid = pid
        self.latest = {}
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.poll_loop, daemon=True)
        self.thread.start()

    def poll_loop(self):
        while not self.stop.wait(0.1):
            self.poll()

    def poll(self):
        with self.lock:
            for task in glob.glob(f"/proc/{self.pid}/task/*"):
                try:
                    with open(f"{task}/comm") as f:
                        comm = f.read().rstrip("\n")
                    with open(f"{task}/stat") as f:
                        stat = f.read()
                except OSError:
                    continue
                # The comm in parentheses may contain spaces; utime and stime are the 14th and
                # 15th field of the line, the 12th and 13th after the closing parenthesis.
                fields = stat.rsplit(")", 1)[1].split()
                self.latest[int(os.path.basename(task))] = (comm, int(fields[11]) + int(fields[12]))

    def snapshot(self):
        self.poll()
        with self.lock:
            return dict(self.latest)


def run(binary, criterion_home):
    """Runs the whole suite under a pty and returns the CPU snapshots at the start and end of
    each benchmark's measurement window, keyed by benchmark id."""
    master, slave = pty.openpty()
    child = subprocess.Popen(
        [binary, "--bench", "--warm-up-time", "0.5", "--measurement-time", "1.5", "--noplot"],
        stdin=slave,
        stdout=slave,
        stderr=slave,
        env=dict(os.environ, CRITERION_HOME=criterion_home),
    )
    os.close(slave)
    cpu = ThreadCpu(child.pid)

    windows = {}

    def note_progress(line):
        match = PROGRESS.match(line)
        if match is None:
            return
        window = windows.setdefault(match["id"], [None, None])
        phase = 0 if match["phase"] == "Collecting" else 1
        if window[phase] is None:
            window[phase] = cpu.snapshot()

    buffer = ""
    while True:
        try:
            chunk = os.read(master, 4096)
        except OSError:
            chunk = b""
        if not chunk:
            break
        buffer += chunk.decode(errors="replace")
        # Criterion overwrites a progress line with a carriage return only when the next one
        # starts, so the unterminated remainder is matched too; it is a full window later.
        *lines, buffer = re.split(r"[\r\n]", buffer)
        for line in lines:
            line = ANSI.sub("", line)
            if line and not line.startswith("Benchmarking "):
                print(line, file=sys.stderr)
            note_progress(line)
        note_progress(ANSI.sub("", buffer))

    cpu.stop.set()
    os.close(master)
    if child.wait() != 0:
        sys.exit(f"{binary} exited with {child.returncode}")

    return windows


def samples(criterion_home):
    """Returns the packets and wall time in nanoseconds criterion measured, keyed by benchmark
    id."""
    result = {}
    for path in glob.glob(f"{criterion_home}/**/new/benchmark.json", recursive=True):
        with open(path) as f:
            full_id = json.load(f)["full_id"]
        with open(os.path.join(os.path.dirname(path), "sample.json")) as f:
            sample = json.load(f)
        result[full_id] = (sum(sample["iters"]), sum(sample["times"]))

    return result


def stage_cpu_ns(start, end, prefix):
    """Returns the CPU time in nanoseconds the stage's threads used between the two snapshots,
    or None when the process had no such thread."""
    threads = [tid for tid, (comm, _) in end.items() if comm.startswith(prefix)]
    if not threads:
        return None

    ticks = sum(end[tid][1] - start.get(tid, (None, 0))[1] for tid in threads)

    return ticks * 1e9 / CLK_TCK


def main(binary, output):
    criterion_home = tempfile.mkdtemp()
    windows = run(binary, criterion_home)
    measured = samples(criterion_home)

    bmf = {}
    for full_id, (packets, wall_ns) in sorted(measured.items()):
        match = BENCHMARK_ID.match(full_id)
        if match is None or full_id not in windows:
            continue
        start, end = windows[full_id]
        if end is None:
            sys.exit(f"{full_id}: criterion never finished collecting samples")

        measures = {"throughput": packets * PACKET_SIZE * 8 / (wall_ns / 1e9)}
        for slug, prefix in STAGES:
            cpu_ns = stage_cpu_ns(start, end, prefix)
            if cpu_ns is not None:
                measures[slug] = cpu_ns / packets

        name = f"event_loop/{match[1]}/{match[2]}"
        bmf[name] = {slug: {"value": value} for slug, value in measures.items()}
        print(
            f"{name}: {measures['throughput'] / 1e9:.2f} Gbit/s, "
            + ", ".join(f"{slug} {value:.0f} ns/packet" for slug, value in measures.items() if slug != "throughput"),
            file=sys.stderr,
        )

    if len(bmf) != 8:
        sys.exit(f"expected 8 benchmarks, got {sorted(bmf)}")

    with open(output, "w") as f:
        json.dump(bmf, f, indent=2)


if __name__ == "__main__":
    main(*sys.argv[1:3])
