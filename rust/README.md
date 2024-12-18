# Rust development guide

Firezone uses Rust for all data plane components. This directory contains the
Linux and Windows clients, and low-level networking implementations related to
STUN/TURN.

We target the last stable release of Rust using [`rust-toolchain.toml`](./rust-toolchain.toml).
If you are using `rustup`, that is automatically handled for you.
Otherwise, ensure you have the latest stable version of Rust installed.

## Reading Client logs

The Client logs are written as [JSONL](https://jsonlines.org/) for machine-readability.

To make them more human-friendly, pipe them through `jq` like this:

```bash
cd path/to/logs  # e.g. `$HOME/.cache/dev.firezone.client/data/logs` on Linux
cat *.log | jq -r '"\(.time) \(.severity) \(.message)"'
```

Resulting in, e.g.

```
2024-04-01T18:25:47.237661392Z INFO started log
2024-04-01T18:25:47.238193266Z INFO GIT_VERSION = 1.0.0-pre.11-35-gcc0d43531
2024-04-01T18:25:48.295243016Z INFO No token / actor_name on disk, starting in signed-out state
2024-04-01T18:25:48.295360641Z INFO null
```

## Benchmarking on Linux

The recommended way for benchmarking any of the Rust components is Linux' `perf` utility.
For example, to attach to a running application, do:

1. Ensure the binary you are profiling is compiled with the `release` profile.
1. `sudo perf record -g --freq 10000 --pid $(pgrep <your-binary>)`.
1. Run the speed test or whatever load-inducing task you want to measure.
1. `sudo perf script > profile.perf`
1. Open [profiler.firefox.com](https://profiler.firefox.com) and load `profile.perf`

Instead of attaching to a process with `--pid`, you can also specify the path to executable directly.
That is useful if you want to capture perf data for a test or a micro-benchmark.
