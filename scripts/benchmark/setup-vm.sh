#!/usr/bin/env bash

# Prepares an ephemeral VM (e.g. a Claude Code web session) for running the
# docker-compose based benchmark harness. Idempotent; safe to re-run.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FAILED_DOMAINS=()

echo "==> Starting docker daemon"
if ! docker info >/dev/null 2>&1; then
    # The init.d script fails on `ulimit` in some VMs; launch dockerd directly.
    nohup dockerd >/var/log/dockerd.log 2>&1 &
    for _ in $(seq 1 30); do
        docker info >/dev/null 2>&1 && break
        sleep 1
    done
    docker info >/dev/null 2>&1 || {
        echo "ERROR: dockerd failed to start; see /var/log/dockerd.log" >&2
        exit 1
    }
fi
echo "    docker $(docker version --format '{{.Server.Version}}') running"

echo "==> Installing host packages"
export DEBIAN_FRONTEND=noninteractive
apt-get install -y --no-install-recommends linux-tools-common linux-tools-generic musl-tools jq iproute2 >/dev/null

if ! perf --version >/dev/null 2>&1; then
    # The perf wrapper wants a linux-tools build matching `uname -r`, which never
    # exists on custom VM kernels. Any recent perf works; link the newest one.
    ln -sf "$(find /usr/lib/linux-tools -name perf | sort -V | tail -1)" /usr/local/bin/perf
    hash -r # bash may have already hashed the failing /usr/bin/perf wrapper
fi
echo "    perf: $(perf --version)"
if perf stat -e cycles -x, true 2>&1 | grep -q "not supported"; then
    echo "    no hardware PMU; profiling will fall back to cpu-clock sampling"
else
    echo "    hardware PMU available (cycles)"
fi

echo "==> Applying kernel sysctls for benchmarking"
sysctl -qw net.core.wmem_max=16777216         # 16 MB
sysctl -qw net.core.rmem_max=134217728        # 128 MB
sysctl -qw net.core.netdev_max_backlog=100000 # matches the netem limit
sysctl -qw net.core.netdev_budget=5000        # drain more per softirq poll

# Kernels with built-in br_netfilter run bridged packets through iptables,
# where docker's inter-network MASQUERADE breaks the compose router topology
# (CI kernels have it off). Same-bridge L2 traffic must bypass iptables.
if [ -f /proc/sys/net/bridge/bridge-nf-call-iptables ]; then
    sysctl -qw net.bridge.bridge-nf-call-iptables=0
    sysctl -qw net.bridge.bridge-nf-call-ip6tables=0 2>/dev/null || true
fi

# Let unprivileged processes (e.g. the iperf3 server container) pick any of
# these congestion controls via TCP_CONGESTION.
sysctl -qw net.ipv4.tcp_allowed_congestion_control="reno cubic bbr" 2>/dev/null ||
    echo "    WARN: could not extend tcp_allowed_congestion_control"

echo "==> Installing Rust toolchain (per rust-toolchain.toml)"
(cd "$REPO_ROOT/rust" && rustup show active-toolchain)

echo "==> Installing relay build dependencies (nightly + bpf-linker; best-effort)"
rustup toolchain install nightly --profile minimal >/dev/null 2>&1 ||
    echo "    WARN: could not install nightly toolchain (needed only for the relay)"
if ! command -v bpf-linker >/dev/null 2>&1; then
    (
        cd "$REPO_ROOT" && mise trust -q 2>/dev/null
        cd rust && mise trust -q 2>/dev/null
        mise install "github:aya-rs/bpf-linker" 2>/dev/null
    ) ||
        echo "    WARN: could not install bpf-linker (needed only for the relay)"
fi

echo "==> Installing inferno for flamegraphs (best-effort)"
if ! command -v inferno-flamegraph >/dev/null 2>&1; then
    cargo install --locked inferno --quiet 2>/dev/null ||
        echo "    WARN: could not install inferno; use 'perf report' instead of flamegraphs"
fi

echo "==> Checking egress to required registries"
check_egress() {
    local domain="$1" url="$2" rc=0
    # A TLS tunnel that cannot even be established (curl exit 56 on CONNECT,
    # or a timeout) means the domain is denied by the environment's network
    # policy. HTTP-level errors (401/403 from the real host) are fine here.
    curl -s -o /dev/null --max-time 15 "$url" || rc=$?
    if [ "$rc" -eq 56 ] || [ "$rc" -eq 28 ]; then
        FAILED_DOMAINS+=("$domain")
    fi
}
# Blob CDNs are usually the only thing missing from restricted network policies;
# the registry front-ends (registry-1.docker.io, ghcr.io) tend to be allowed.
check_egress "production.cloudfront.docker.com (Docker Hub blobs)" \
    "https://production.cloudfront.docker.com/"
check_egress "pkg-containers.githubusercontent.com (ghcr.io blobs)" \
    "https://pkg-containers.githubusercontent.com/"

if ((${#FAILED_DOMAINS[@]} > 0)); then
    echo ""
    echo "ERROR: some registry endpoints are not reachable:" >&2
    printf '    - %s\n' "${FAILED_DOMAINS[@]}" >&2
    cat >&2 <<'EOF'

Image pulls will fail. Allow the following domains in the network policy of
this Claude Code environment (Settings -> Environments -> Network policy):

    production.cloudfront.docker.com     # Docker Hub blob CDN
    pkg-containers.githubusercontent.com # ghcr.io blob CDN
    api.github.com                       # release assets for mise-managed tools (bpf-linker)
    dl-cdn.alpinelinux.org               # apk (only for stock `docker compose build` images)
EOF
    exit 1
fi

echo ""
echo "VM is ready. Next steps:"
echo "    scripts/benchmark/build-binaries.sh"
echo "    scripts/benchmark/run.sh tcp-client2server"
