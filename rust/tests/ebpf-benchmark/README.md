# eBPF benchmark

Microbenchmark for the [`handle_turn`](../../relay/ebpf-turn-router) XDP program.

It loads the compiled eBPF object, populates the routing maps for a single IPv4
channel binding and measures the in-kernel processing cost of the two IPv4 data
paths with `bpftool prog run` (the `BPF_PROG_TEST_RUN` command). `bpftool` runs
the JIT-compiled program `--repeat N` times inside one syscall and returns the
average nanoseconds per run, excluding the packet copies and syscall overhead.

Two paths are covered:

- `forward`: IPv4 UDP -> IPv4 ChannelData (the program prepends the 4-byte channel-data header)
- `reverse`: IPv4 ChannelData -> IPv4 UDP (the program strips the channel-data header)

The relayed-payload sweep is capped at `MAX_IP_SIZE + WG_OVERHEAD` (the largest
WireGuard packet the relay ever forwards); the reverse path's largest input
therefore equals `MAX_FZ_PAYLOAD`.

The measurement reflects the packet transformation only: the program is loaded
without a userspace log reader, so its hot-path `trace!` statements are filtered
in-kernel and contribute no perf-buffer writes (as in a relay not running at `TRACE`).

## Prerequisites

- **Linux** with a kernel that supports XDP `BPF_PROG_TEST_RUN` (any recent 5.x+).
- **Root** (or `CAP_BPF` + `CAP_PERFMON`) to load the program and run the test.
- **`bpftool`** on `PATH` (or pass `--bpftool <path>`). It is *not* declared in
  `mise.toml`; install it from your distribution (e.g. `linux-tools-$(uname -r)`)
  or build it from the kernel tree (`tools/bpf/bpftool`).
- Toolchain to build the eBPF object: `nightly-2025-05-30` + `rust-src` and
  `bpf-linker` (see [`rust/README.md`](../../README.md); `bpf-linker` is provided
  by `mise`).

## Run

```
cargo build -p ebpf-benchmark
sudo ./target/debug/ebpf-benchmark
```

(`sudo cargo run -p ebpf-benchmark` also works.) For reproducible numbers, pin to
a single CPU and use the performance governor:

```
sudo taskset -c 2 ./target/debug/ebpf-benchmark
```

### Options

- `--repeat <N>` kernel-side repetitions per invocation (default `1000000`).
- `--invocations <K>` invocations per case; the median is reported (default `10`).
- `--sizes <a,b,c>` relayed-payload sizes in bytes (default spread up to the max).
- `--direction <forward|reverse|both>` (default `both`).
- `--bpftool <path>` path to `bpftool`.
- `--csv` emit CSV instead of a table.
- `--no-warmup` skip the discarded warmup invocation.
