FROM lukemathwalker/cargo-chef:latest-rust-1.72-slim-bookworm as chef

# See https://github.com/LukeMathWalker/cargo-chef/issues/231.
COPY rust-toolchain.toml rust-toolchain.toml

WORKDIR /build

FROM chef as planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json

FROM chef as builder
COPY --from=planner /build/recipe.json .
RUN cargo chef cook --release --recipe-path recipe.json
COPY . .
ARG PACKAGE
RUN cargo build -p $PACKAGE --release

FROM debian:bookworm-slim AS runtime
WORKDIR /app
ARG PACKAGE
COPY --from=builder /build/target/release/$PACKAGE .
RUN ln -s ./${PACKAGE} ./app
COPY ./docker-init.sh .
ENV RUST_BACKTRACE=1
ENV PATH "/app:$PATH"
ENV PACKAGE_NAME ${PACKAGE}
RUN apt-get -qq update \
    && DEBIAN_FRONTEND=noninteractive \
    apt-get -qq install \
      iputils-ping \
      iptables \
      lsof \
      iproute2 \
      curl \
      iperf3 \
      ca-certificates \
    && apt-get -qq clean \
    && rm -rf /var/lib/apt/lists/*

ENTRYPOINT ["docker-init.sh"]
CMD ["app"]
