FROM debian:12-slim

ARG DEBIAN_FRONTEND=noninteractive
RUN --mount=type=cache,target=/var/cache/apt apt-get update && apt-get -y install iproute2 nftables jq tcpdump iputils-ping

COPY *.sh /scripts/
RUN chmod +x /scripts/*.sh

HEALTHCHECK CMD [ "sh", "-c", "test $(cat /tmp/setup_done) = 1" ]

ENTRYPOINT ["./scripts/run.sh"]
