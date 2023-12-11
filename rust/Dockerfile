# Global args to use in build commands
ARG ALPINE_VERSION="3.19"
ARG CARGO_CHEF_VERSION="0.1.62"

# This image is used to prepare Cargo Chef which is used to cache dependencies
FROM rust:1-alpine${ALPINE_VERSION} as chef

ARG CARGO_CHEF_VERSION
RUN set -xe \
  && apk add --no-cache musl-dev  \
  && cargo install cargo-chef --locked --version=${CARGO_CHEF_VERSION} \
  && rm -rf $CARGO_HOME/registry/

## See https://github.com/LukeMathWalker/cargo-chef/issues/231.
COPY rust-toolchain.toml rust-toolchain.toml

RUN set -xe \
  && rustup show

WORKDIR /build

# Create a cache recipe for dependencies, which allows
# to levearge Docker layer caching in a later build stage
FROM chef as planner

COPY . .

RUN cargo chef prepare --recipe-path recipe.json

# Build dependencies and application application
FROM chef as builder

COPY --from=planner /build/recipe.json .

RUN set -xe \
  && cargo chef cook --recipe-path recipe.json

COPY . .

ARG TARGET
ARG PACKAGE
RUN cargo build -p ${PACKAGE} $([ -v "${TARGET}" ] && "--target ${TARGET}")

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

# Build an image for GitHub Actions which includes debug asserts
FROM runtime AS debug

RUN set -xe \
  && apk add --no-cache iperf3

ARG TARGET
COPY --from=builder /build/target/${TARGET}/debug/${PACKAGE} .

# Build a production image from including a binary compiled on the host
FROM runtime AS release

ARG TARGET
## Build first with `cross build --target ${TARGET} -p ${PACKAGE} --release && mv /target/${TARGET}/release/${PACKAGE} .`
COPY ${PACKAGE} .
