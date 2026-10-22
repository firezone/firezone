FROM ubuntu:24.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends iproute2 \
    && rm -rf /var/lib/apt/lists/*

COPY tunnel-bench /usr/local/bin/

WORKDIR /tmp

# The Bare Metal VM brings up no network interfaces, and its socket buffer limits are too small
# for the event loop to keep up without dropping packets.
ENTRYPOINT ["sh", "-c", "ip link set lo up && echo 16777216 > /proc/sys/net/core/rmem_max && echo 16777216 > /proc/sys/net/core/wmem_max && exec tunnel-bench --bench"]
