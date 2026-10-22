FROM ubuntu:24.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends iproute2 python3 \
    && rm -rf /var/lib/apt/lists/*

COPY tunnel-bench backfill.py /usr/local/bin/

WORKDIR /tmp

# The Bare Metal VM brings up no network interfaces and mounts no devpts for the wrapper's pseudo-terminal, and its socket buffer limits are too small
# for the event loop to keep up without dropping packets.
ENTRYPOINT ["sh", "-c", "ip link set lo up && mkdir -p /dev/pts && mount -t devpts -o newinstance,ptmxmode=0666 devpts /dev/pts && ln -sf pts/ptmx /dev/ptmx && echo 16777216 > /proc/sys/net/core/rmem_max && echo 16777216 > /proc/sys/net/core/wmem_max && exec python3 /usr/local/bin/backfill.py /usr/local/bin/tunnel-bench /tmp/tunnel-bench.json"]
