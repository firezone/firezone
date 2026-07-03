---
name: benchmark
description: Benchmark and profile the Firezone data plane (client/gateway/relay throughput via iperf3) using the docker-compose topology, including perf profiles and flamegraphs. Use when asked to benchmark Firezone, measure or compare tunnel throughput, capture CPU profiles of connlib/boringtun, or evaluate a performance-related code change.
---

# Benchmarking Firezone in this VM

This harness runs the same iperf3-through-the-tunnel scenarios as CI's
`_perf_tests.yml`, entirely inside this VM (Claude Code web sessions run as
root in a microVM: docker, perf and sysctl all work).

## One-time session setup

```sh
scripts/benchmark/setup-vm.sh   # dockerd, perf, sysctls, toolchain, egress preflight
```

If it reports blocked registry domains, STOP and tell the user which domains
to allow in the Claude Code environment's network policy; nothing else will
work until then.

## Running a benchmark

```sh
scripts/benchmark/build-binaries.sh                     # release binaries with frame pointers -> rust/
scripts/benchmark/run.sh --label baseline tcp-client2server
scripts/benchmark/run.sh --label baseline --profile --flavour relayed udp-client2server
```

- Tests: `tcp-client2server`, `tcp-server2client`, `udp-client2server`, `udp-server2client`.
- Flavours: `direct` (default) or `relayed` (TURN via the relay; forces client masquerading).
- Results land in `bench-results/<label>/`: raw iperf3 JSON, a `.summary.json`
  (throughput/retransmits/loss), and with `--profile` per-process
  `.perf.data` files plus flamegraph `.svg`s.
- Inspect profiles with `perf report -i <file>.perf.data --stdio` or send the
  SVGs to the user.

## Iterating on a code change

The stack stays up between runs. After editing Rust code:

```sh
scripts/benchmark/build-binaries.sh firezone-gateway    # only what changed
docker compose -f docker-compose.yml -f scripts/benchmark/compose.ipv4.yml -f scripts/benchmark/compose.bench.yml up -d --build gateway
scripts/benchmark/run.sh --label my-change tcp-client2server
```

(`run.sh` exports the same `COMPOSE_FILE` list; omit `compose.ipv4.yml` on
kernels that have IPv6.) Run each scenario at least 3 times per variant and
compare medians; single runs on a shared 4-vCPU VM are noisy. Always record a
baseline from unmodified code in the same session before comparing.

To benchmark a boringtun change, check out the boringtun repo next to this one
and add to `rust/Cargo.toml` under `[patch."https://github.com/firezone/boringtun"]`:
`boringtun = { path = "../../boringtun/boringtun" }` — then rebuild.

Teardown: `docker compose down` (add `-v` to reset the seeded database).

## Interpreting results — caveats

- Numbers are only meaningful RELATIVE to a baseline captured on the same VM
  in the same session. Client, gateway, relay, routers and iperf all share ~4
  vCPUs, so absolute throughput is far below CI/production.
- No hardware PMU: profiles use `cpu-clock` sampling (wall-clock-ish CPU
  time), not cycles. No cache/branch counters.
- The VM kernel has no `netem` (and `ipv6.disable=1`, hence the IPv4-only
  compose overlay): latency emulation via `*_LATENCY_MS` env vars silently
  cannot work here, and IPv6 paths are not exercised.
- Debug-image bases run release binaries (same recipe as CI `perf/*` images).
- This kernel's default TCP congestion control is BBR (CI hosts default to
  cubic) and containers inherit it — pin `-C cubic`/`-C bbr` explicitly when
  running iperf3 by hand. The relay runs without eBPF offload here (the
  kernel's verifier rejects the TURN router program).
- Check `docker compose logs client-1 gateway relay-1` for WARNs after a run;
  CI treats those as failures.
