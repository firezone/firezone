# Global args to use in build commands
ARG ALPINE_VERSION="3.18"

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
ARG TARGET="x86_64-unknown-linux-musl"
ARG PACKAGE
RUN cargo build -p ${PACKAGE} --target ${TARGET}

# Minimal test image for GH actions
FROM alpine:${ALPINE_VERSION} AS debug
WORKDIR /bin
ENV RUST_BACKTRACE=1
COPY ./docker-init.sh .
ARG TARGET="x86_64-unknown-linux-musl"
ARG PACKAGE
COPY --from=builder /build/target/${TARGET}/debug/${PACKAGE} .
ENTRYPOINT ["docker-init.sh"]
CMD ${PACKAGE}


# Minimal platform-agnostic release image
FROM alpine:${ALPINE_VERSION} AS release
WORKDIR /bin
ENV RUST_BACKTRACE=1
COPY ./docker-init.sh .
ARG TARGET
ARG PACKAGE
# Build first with `cross build --target ${TARGET} -p ${PACKAGE} --release`
COPY ./target/${TARGET}/release/${PACKAGE} .
ENTRYPOINT ["docker-init.sh"]
CMD ${PACKAGE}
