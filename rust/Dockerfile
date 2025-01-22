# Keep synced with `rust-toolchain.toml`
ARG RUST_VERSION="1.84.0"
ARG ALPINE_VERSION="3.20"
ARG CARGO_CHEF_VERSION="0.1.67"

ARG PACKAGE

# This image is used to prepare Cargo Chef which is used to cache dependencies
# Keep the Rust version synced with `rust-toolchain.toml`
FROM rust:${RUST_VERSION}-alpine${ALPINE_VERSION} AS chef

ARG CARGO_CHEF_VERSION
# openssl-dev can be removed after https://github.com/tauri-apps/tauri/pull/12445 is shipped
RUN set -xe \
    && apk add --no-cache musl-dev openssl-dev \
    && cargo install cargo-chef --locked --version=${CARGO_CHEF_VERSION} \
    && rm -rf $CARGO_HOME/registry/

## See https://github.com/LukeMathWalker/cargo-chef/issues/231.
COPY rust-toolchain.toml rust-toolchain.toml

RUN rustup show

WORKDIR /build

# Create a cache recipe for dependencies, which allows
# to leverage Docker layer caching in a later build stage
FROM chef AS planner

COPY . .

RUN cargo chef prepare --recipe-path recipe.json

# Build dependencies and application application
FROM chef AS builder

COPY --from=planner /build/recipe.json .

ARG PACKAGE
RUN set -xe \
    && cargo chef cook --recipe-path recipe.json --bin ${PACKAGE}

COPY . .

ARG TARGET
RUN cargo build -p ${PACKAGE} $([ -n "${TARGET}" ] && "--target ${TARGET}")

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

# used as a base for dev and test
FROM runtime AS test

RUN apk add --no-cache iperf3 bind-tools iproute2 jq procps

# used for local development
FROM test AS dev
ARG TARGET
ARG PACKAGE
COPY --from=builder /build/target/${TARGET}/debug/${PACKAGE} .

# Build an image for GitHub Actions which includes debug asserts and more test utilities
FROM test AS debug

## Build first with `cross build --target ${TARGET} -p ${PACKAGE} && mv /target/${TARGET}/release/${PACKAGE} .`
ARG PACKAGE
COPY ${PACKAGE} .

# Build a production image from including a binary compiled on the host
FROM runtime AS release

## Build first with `cross build --target ${TARGET} -p ${PACKAGE} --release && mv /target/${TARGET}/release/${PACKAGE} .`
ARG PACKAGE
COPY ${PACKAGE} .
