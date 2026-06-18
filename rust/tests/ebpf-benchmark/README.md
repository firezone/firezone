# eBPF benchmark

Measures the in-kernel processing cost of the
[`handle_turn`](../../relay/ebpf-turn-router) XDP program with `bpftool prog run`,
for the two IPv4 data paths (UDP → ChannelData and back) across a range of payload
sizes up to the maximum Firezone relays.

## Run

```sh
cargo run -p ebpf-benchmark   # --help for options
```

The binary re-execs itself under `sudo` (it needs `CAP_BPF`/`CAP_PERFMON` to load the
program and run `BPF_PROG_TEST_RUN`), so no manual `sudo` is needed. Requires a
`CONFIG_BPF_JIT=y` kernel and the eBPF toolchain — `nightly-2025-05-30`, `bpf-linker`
and `bpftool`, all via `mise` (see [`rust/README.md`](../../README.md)). When `bpftool`
is the mise shim, pass `--bpftool "$(mise which bpftool)"` since `sudo` strips mise's env.
