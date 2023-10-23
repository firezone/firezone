# Global args to use in build commands
ARG ALPINE_VERSION="3.18"
ARG PACKAGE

FROM lukemathwalker/cargo-chef:latest-rust-alpine${ALPINE_VERSION} as chef

# See https://github.com/LukeMathWalker/cargo-chef/issues/231.
COPY rust-toolchain.toml rust-toolchain.toml
RUN rustup show

WORKDIR /build

FROM chef as planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

FROM chef as builder
COPY --from=planner /build/recipe.json .
RUN cargo chef cook --recipe-path recipe.json
COPY . .
ARG TARGET
ARG PACKAGE
RUN cargo build -p ${PACKAGE} $([ -v "${TARGET}" ] && "--target ${TARGET}")

# Minimal test image for GH actions
FROM alpine:${ALPINE_VERSION} AS debug
WORKDIR /bin
ENV RUST_BACKTRACE=1
COPY ./docker-init.sh .
ARG PACKAGE
# Needed only by gateway for masquerading
RUN \[ "${PACKAGE}" = "firezone-gateway" ] && apk add --no-cache iptables ip6tables || true
ARG TARGET
COPY --from=builder /build/target/${TARGET}/debug/${PACKAGE} .
ENTRYPOINT ["docker-init.sh"]
ENV PACKAGE=${PACKAGE}
CMD $PACKAGE

# Minimal platform-agnostic release image
FROM alpine:${ALPINE_VERSION} AS release
WORKDIR /bin
ENV RUST_BACKTRACE=1
COPY ./docker-init.sh .
ARG PACKAGE
# Needed only by gateway for masquerading
RUN \[ "${PACKAGE}" = "firezone-gateway" ] && apk add --no-cache iptables ip6tables || true
ARG TARGET
# Build first with `cross build --target ${TARGET} -p ${PACKAGE} --release && mv /target/${TARGET}/release/${PACKAGE} .`
COPY ${PACKAGE} .
ENTRYPOINT ["docker-init.sh"]
ENV PACKAGE=${PACKAGE}
CMD $PACKAGE
