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
