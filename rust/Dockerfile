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
RUN apk add --no-cache --update curl

# Gateway specific runtime base image
FROM runtime_base AS runtime_firezone-gateway
## iptables are needed only by gateway for masquerading
RUN apk add --no-cache --update iptables ip6tables
COPY ./docker-init-gateway.sh ./docker-init.sh

# Relay specific runtime base image
FROM runtime_base AS runtime_firezone-relay
RUN apk add --no-cache --update xdp-tools
COPY ./docker-init-relay.sh ./docker-init.sh

# Headless-client specific runtime base image
FROM runtime_base AS runtime_firezone-headless-client
COPY ./docker-init-client.sh ./docker-init.sh

# HTTP test server specific runtime base image
FROM runtime_base AS runtime_http-test-server
COPY ./docker-init-http-test-server.sh ./docker-init.sh

# Funnel package specific base image back into `runtime`
ARG PACKAGE
FROM runtime_${PACKAGE} AS runtime

ARG PACKAGE
ENTRYPOINT ["docker-init.sh"]
ENV PACKAGE=${PACKAGE}

CMD ${PACKAGE}

# Build an image for GitHub Actions which includes debug asserts and more test utilities
FROM runtime AS debug

RUN apk add --no-cache --update iperf3 bind-tools iproute2 jq procps iptables ethtool

## Build first with `cargo build --target ${TARGET} -p ${PACKAGE} && mv /target/${TARGET}/debug/${PACKAGE} .`
ARG PACKAGE
COPY ${PACKAGE} .

# Build a production image from including a binary compiled on the host
FROM runtime AS release

## Build first with `cargo build --target ${TARGET} -p ${PACKAGE} --release && mv /target/${TARGET}/release/${PACKAGE} .`
ARG PACKAGE
COPY ${PACKAGE} .

FROM runtime AS dev

ARG PACKAGE
ARG RUST_VERSION="1.93.0" # Keep in sync with `rust-toolchain.toml`

WORKDIR /app

RUN apk add --no-cache rustup sccache build-base
RUN /usr/bin/rustup-init -y --default-toolchain ${RUST_VERSION} --profile minimal

# Configure sccache
ENV RUSTC_WRAPPER=sccache
ENV SCCACHE_DIR=/sccache
ENV SCCACHE_CACHE_SIZE=20G

COPY . .

RUN --mount=type=cache,target=./target \
    --mount=type=cache,target=/sccache \
    /root/.cargo/bin/cargo build -p ${PACKAGE} && \
    cp target/debug/${PACKAGE} /bin

WORKDIR /bin
