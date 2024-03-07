ARG ALPINE_VERSION="3.19"

FROM rust:1.74-alpine as rust

RUN set -xe \
  # Upgrade Alpine and base packages
  && apk --no-cache --update-cache --available upgrade \
  # Install required deps
  && apk add --no-cache --update-cache \
  ca-certificates \
  gcc

# This image is used to prepare Cargo Chef which is used to cache dependencies
FROM rust as chef
RUN set -xe \
  && apk add --no-cache musl-dev \
  && rm -rf $CARGO_HOME/registry/

## See https://github.com/LukeMathWalker/cargo-chef/issues/231.
COPY rust-toolchain.toml rust-toolchain.toml

WORKDIR /build

# Create a cache recipe for dependencies, which allows
# to leverage Docker layer caching in a later build stage
FROM chef as planner

COPY . .

# Build dependencies and application application
FROM chef as builder

ARG PACKAGE

COPY . .

ARG TARGET
ARG PACKAGE
ENV CONNLIB_LOG_UPLOAD_INTERVAL_SECS=300
RUN cargo build -p ${PACKAGE} $([ -n "${TARGET}" ] && "--target ${TARGET}")

# Image which is used to run the application binary
FROM alpine:${ALPINE_VERSION} AS runtime

# Important!  Update this no-op ENV variable when this Dockerfile
# is updated with the current date. It will force refresh of all
# of the base images and things like `apk add` won't be using
# old cached versions when the Dockerfile is built.
ENV REFRESHED_AT=2023-10-23 \
  LANG=C.UTF-8 \
  TERM=xterm \
  RUST_BACKTRACE=1

WORKDIR /bin

## curl is needed by the entrypoint script
RUN set -xe \
  && apk add --no-cache curl

COPY ./docker-init.sh .

## iptables are needed only by gateway for masquerading
ARG PACKAGE
RUN set -xe \
  && \[ "${PACKAGE}" = "firezone-gateway" ] && apk add --no-cache iptables ip6tables || true

ENTRYPOINT ["docker-init.sh"]

ENV PACKAGE=${PACKAGE}

CMD $PACKAGE

# used for local development
FROM runtime as development

RUN set -xe \
  && apk add --no-cache iperf3 bind-tools iproute2 jq

# Build an image for GitHub Actions which includes debug asserts and test utilities
FROM development AS debug

ARG TARGET
COPY --from=builder /build/target/${TARGET}/debug/${PACKAGE} .

# Build a production image from including a binary compiled on the host
FROM runtime AS release

ARG TARGET
## Build first with `cross build --target ${TARGET} -p ${PACKAGE} --release && mv /target/${TARGET}/release/${PACKAGE} .`
COPY ${PACKAGE} .
