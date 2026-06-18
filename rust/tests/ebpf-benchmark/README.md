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
and `bpftool`, all via `mise` (see [`rust/README.md`](../../README.md)). `bpftool` comes
from mise's github backend, which installs no shim, so resolve and pass it explicitly
(`sudo` strips mise's env regardless):

```sh
bpftool="$(mise where github:libbpf/bpftool)/bpftool"
chmod +x "$bpftool"   # the release tarball is mode 0644
cargo run -p ebpf-benchmark -- --bpftool "$bpftool"
```
