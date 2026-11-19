FROM ubuntu:24.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends iproute2 \
    && rm -rf /var/lib/apt/lists/*

COPY tunnel-bench /usr/local/bin/

WORKDIR /tmp

# The Bare Metal VM brings up no network interfaces.
ENTRYPOINT ["sh", "-c", "ip link set lo up && TUNNEL_BENCH_JSON=/tmp/tunnel-bench.json exec tunnel-bench --bench"]
