# eBPF benchmark

Measures the in-kernel processing cost of the
[`handle_turn`](../../relay/ebpf-turn-router) XDP program with `bpftool prog run`,
for the two IPv4 data paths (UDP → ChannelData and back) across a range of payload
sizes up to the maximum Firezone relays.

## Run

```sh
cargo build -p ebpf-benchmark
sudo ./target/debug/ebpf-benchmark   # --help for options
```

Requires Linux with `CONFIG_BPF_JIT=y`, root (for `BPF_PROG_TEST_RUN`), `bpftool` on
`PATH`, and the eBPF build toolchain — `nightly-2025-05-30` + `bpf-linker` via `mise`
(see [`rust/README.md`](../../README.md)).
