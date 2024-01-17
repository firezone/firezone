# Global args to use in build commands
ARG DEBIAN_VERSION="12-slim"
ARG CARGO_CHEF_VERSION="0.1.62"
ARG RUSTUP_VERSION="1.26.0"
ARG RUSTUP_x86_DOWNLOAD_SHA256="0b2f6c8f85a3d02fde2efc0ced4657869d73fccfce59defb4e8d29233116e6db"
ARG RUSTUP_aarch64_DOWNLOAD_SHA256="673e336c81c65e6b16dcdede33f4cc9ed0f08bde1dbe7a935f113605292dc800"
ARG RUST_VERSION="1.74.1"

FROM debian:${DEBIAN_VERSION} as rust

# Important!  Update this no-op ENV variable when this Dockerfile
# is updated with the current date. It will force refresh of all
# of the base images and things like `apk add` won't be using
# old cached versions when the Dockerfile is built.
ENV REFRESHED_AT=2023-12-11 \
  DEBIAN_FRONTEND=noninteractive \
  LANG=C.UTF-8 \
  TERM=xterm

RUN set -xe \
  # Upgrade Debian and base packages
  && apt-get update -qq \
  # Install required deps
  && apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  gcc \
  libc6-dev

ENV RUSTUP_HOME=/usr/local/rustup \
  CARGO_HOME=/usr/local/cargo \
  PATH=/usr/local/cargo/bin:$PATH

ARG RUSTUP_VERSION
ARG RUSTUP_x86_DOWNLOAD_SHA256
ARG RUSTUP_aarch64_DOWNLOAD_SHA256
ARG RUST_VERSION
RUN set -eux; \
  arch="$(uname -m)"; \
  case "$arch" in \
  x86_64) rustTarget='x86_64-unknown-linux-gnu'; rustupSha256=${RUSTUP_x86_DOWNLOAD_SHA256} ;; \
  aarch64) rustTarget='aarch64-unknown-linux-gnu'; rustupSha256=${RUSTUP_aarch64_DOWNLOAD_SHA256} ;; \
  *) echo >&2 "unsupported architecture: $arch"; exit 1 ;; \
  esac; \
  url="https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${rustTarget}/rustup-init"; \
  curl "$url" -O; \
  echo "${rustupSha256} *rustup-init" | sha256sum -c -; \
  chmod +x rustup-init; \
  ./rustup-init -y --no-modify-path --profile minimal --default-toolchain ${RUST_VERSION} --default-host ${rustTarget}; \
  rm rustup-init; \
  chmod -R a+w $RUSTUP_HOME $CARGO_HOME; \
  rustup --version; \
  cargo --version; \
  rustc --version;

# This image is used to prepare Cargo Chef which is used to cache dependencies
FROM rust as chef

ARG CARGO_CHEF_VERSION
RUN set -xe \
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
RUN cargo build -p ${PACKAGE} $([ -n "${TARGET}" ] && "--target ${TARGET}")

# Image which is used to run the application binary
FROM debian:${DEBIAN_VERSION} AS runtime

# Important!  Update this no-op ENV variable when this Dockerfile
# is updated with the current date. It will force refresh of all
# of the base images and things like `apk add` won't be using
# old cached versions when the Dockerfile is built.
ENV REFRESHED_AT=2023-10-23 \
  DEBIAN_FRONTEND=noninteractive \
  LANG=C.UTF-8 \
  TERM=xterm \
  RUST_BACKTRACE=1

WORKDIR /bin

## curl is needed by the entrypoint script
RUN set -xe \
  && apt-get update -qq \
  && apt-get install -y --no-install-recommends curl

COPY ./docker-init.sh .

## iptables are needed only by gateway for masquerading
ARG PACKAGE
RUN set -xe \
  && \[ "${PACKAGE}" = "firezone-gateway" ] \
  && apt-get update -qq \
  && apt-get install -y --no-install-recommends iptables || true

ENTRYPOINT ["docker-init.sh"]

ENV PACKAGE=${PACKAGE}

CMD $PACKAGE

# Build an image for GitHub Actions which includes debug asserts
FROM runtime AS debug

RUN set -xe \
  && apt-get update -qq \
  && apt-get install -y --no-install-recommends iperf3

ARG TARGET
COPY --from=builder /build/target/${TARGET}/debug/${PACKAGE} .

# Build a production image from including a binary compiled on the host
FROM runtime AS release

ARG TARGET
## Build first with `cross build --target ${TARGET} -p ${PACKAGE} --release && mv /target/${TARGET}/release/${PACKAGE} .`
COPY ${PACKAGE} .
