ARG ALPINE_VERSION="3.20"

ARG PACKAGE

# Base image which is used to run the application binary
FROM alpine:${ALPINE_VERSION} AS runtime_base

ENV LANG=C.UTF-8 \
    TERM=xterm \
    RUST_BACKTRACE=1 \
    RUST_LOG=info

WORKDIR /bin

## curl is needed to run tests (`main` runs CI against `release` images) and `firezone-relay` needs `curl` in its entry script.
RUN apk add --no-cache curl

# Gateway specific runtime base image
FROM runtime_base AS runtime_firezone-gateway
## iptables are needed only by gateway for masquerading
RUN apk add --no-cache iptables ip6tables
COPY ./docker-init-gateway.sh ./docker-init.sh

# Relay specific runtime base image
FROM runtime_base AS runtime_firezone-relay
COPY ./docker-init-relay.sh ./docker-init.sh

# Headless-client specific runtime base image
FROM runtime_base AS runtime_firezone-headless-client
COPY ./docker-init.sh ./docker-init.sh

# HTTP test server specific runtime base image
FROM runtime_base AS runtime_http-test-server
COPY ./docker-init.sh ./docker-init.sh

# Funnel package specific base image back into `runtime`
ARG PACKAGE
FROM runtime_${PACKAGE} AS runtime

ARG PACKAGE
ENTRYPOINT ["docker-init.sh"]
ENV PACKAGE=${PACKAGE}

CMD ${PACKAGE}

# Build an image for GitHub Actions which includes debug asserts and more test utilities
FROM runtime AS debug

RUN apk add --no-cache iperf3 bind-tools iproute2 jq procps

## Build first with `cargo build --target ${TARGET} -p ${PACKAGE} && mv /target/${TARGET}/debug/${PACKAGE} .`
ARG PACKAGE
COPY ${PACKAGE} .

# Build a production image from including a binary compiled on the host
FROM runtime AS release

## Build first with `cargo build --target ${TARGET} -p ${PACKAGE} --release && mv /target/${TARGET}/release/${PACKAGE} .`
ARG PACKAGE
COPY ${PACKAGE} .
