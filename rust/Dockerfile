# Global args to use in build commands
ARG ALPINE_VERSION="3.19"
ARG CARGO_CHEF_VERSION="0.1.62"
ARG RUSTUP_VERSION="1.26.0"
ARG RUSTUP_x86_DOWNLOAD_SHA256="7aa9e2a380a9958fc1fc426a3323209b2c86181c6816640979580f62ff7d48d4"
ARG RUSTUP_aarch64_DOWNLOAD_SHA256="b1962dfc18e1fd47d01341e6897cace67cddfabf547ef394e8883939bd6e002e"
ARG RUST_VERSION="1.74.1"

FROM alpine:${ALPINE_VERSION} as rust

# Important!  Update this no-op ENV variable when this Dockerfile
# is updated with the current date. It will force refresh of all
# of the base images and things like `apk add` won't be using
# old cached versions when the Dockerfile is built.
ENV REFRESHED_AT=2023-12-11 \
  LANG=C.UTF-8 \
  TERM=xterm

RUN set -xe \
  # Upgrade Alpine and base packages
  && apk --no-cache --update-cache --available upgrade \
  # Install required deps
  && apk add --no-cache --update-cache \
  ca-certificates \
  gcc

ENV RUSTUP_HOME=/usr/local/rustup \
  CARGO_HOME=/usr/local/cargo \
  PATH=/usr/local/cargo/bin:$PATH

ARG RUSTUP_VERSION
ARG RUSTUP_x86_DOWNLOAD_SHA256
ARG RUSTUP_aarch64_DOWNLOAD_SHA256
ARG RUST_VERSION
RUN set -eux; \
  apkArch="$(apk --print-arch)"; \
  case "$apkArch" in \
  x86_64) rustArch='x86_64-unknown-linux-musl'; rustupSha256=${RUSTUP_x86_DOWNLOAD_SHA256} ;; \
  aarch64) rustArch='aarch64-unknown-linux-musl'; rustupSha256=${RUSTUP_aarch64_DOWNLOAD_SHA256} ;; \
  *) echo >&2 "unsupported architecture: $apkArch"; exit 1 ;; \
  esac; \
  url="https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${rustArch}/rustup-init"; \
  wget "$url"; \
  echo "${rustupSha256} *rustup-init" | sha256sum -c -; \
  chmod +x rustup-init; \
  ./rustup-init -y --no-modify-path --profile minimal --default-toolchain ${RUST_VERSION} --default-host ${rustArch}; \
  rm rustup-init; \
  chmod -R a+w $RUSTUP_HOME $CARGO_HOME; \
  rustup --version; \
  cargo --version; \
  rustc --version;

# This image is used to prepare Cargo Chef which is used to cache dependencies
FROM rust as chef

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

# Build an image for GitHub Actions which includes debug asserts and test utilities
FROM runtime AS debug

RUN set -xe \
  && apk add --no-cache iperf3 jq

ARG TARGET
COPY --from=builder /build/target/${TARGET}/debug/${PACKAGE} .

# Build a production image from including a binary compiled on the host
FROM runtime AS release

ARG TARGET
## Build first with `cross build --target ${TARGET} -p ${PACKAGE} --release && mv /target/${TARGET}/release/${PACKAGE} .`
COPY ${PACKAGE} .
