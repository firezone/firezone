#!/usr/bin/env bash

# Setup script for a Claude Code web environment used for Firezone
# benchmarking. Paste into (or reference from) the environment's setup script
# so new sessions start with docker, perf and kernel tuning already in place.
#
# Self-contained on purpose: it must work even when the checked-out branch does
# not contain scripts/benchmark/ yet. Everything is best-effort so session
# start never blocks on a transient failure.

export DEBIAN_FRONTEND=noninteractive

# Docker daemon: the init.d script trips on `ulimit` in these VMs, so launch
# dockerd directly.
if ! docker info >/dev/null 2>&1; then
    nohup dockerd >/var/log/dockerd.log 2>&1 &
fi

apt-get install -y --no-install-recommends \
    linux-tools-common linux-tools-generic musl-tools jq iproute2 socat iperf3 shellcheck shfmt || true

# The perf wrapper wants a linux-tools build matching `uname -r`, which never
# exists for these custom VM kernels; any recent perf works.
if ! perf --version >/dev/null 2>&1; then
    ln -sf "$(find /usr/lib/linux-tools -name perf | sort -V | tail -1)" /usr/local/bin/perf
fi

# Kernel tuning to match CI perf tests (resets on every VM boot).
sysctl -qw net.core.wmem_max=16777216
sysctl -qw net.core.rmem_max=134217728
sysctl -qw net.core.netdev_max_backlog=100000
sysctl -qw net.core.netdev_budget=5000

# br_netfilter is built into these kernels and routes bridged packets through
# iptables, where docker's MASQUERADE breaks the compose router topology.
sysctl -qw net.bridge.bridge-nf-call-iptables=0 || true
sysctl -qw net.bridge.bridge-nf-call-ip6tables=0 || true

# Let unprivileged processes (e.g. the iperf3 server container) pick any of
# these congestion controls via TCP_CONGESTION.
sysctl -qw net.ipv4.tcp_allowed_congestion_control="reno cubic bbr" || true

# Flamegraph tooling; slow (cargo build), so run in the background.
if ! command -v inferno-flamegraph >/dev/null 2>&1; then
    nohup cargo install --locked inferno --quiet >/var/log/inferno-install.log 2>&1 &
fi

# Warm the pinned Rust toolchain if the repo is already checked out.
for repo in "$PWD/firezone" "$PWD" /home/user/firezone; do
    if [ -f "$repo/rust/rust-toolchain.toml" ]; then
        (cd "$repo/rust" && nohup rustup show active-toolchain >/dev/null 2>&1 &)
        break
    fi
done

exit 0
