FROM rust:1.72-slim as BUILDER
ARG PACKAGE
WORKDIR /build/
COPY . ./

# This prevents cache hits in GitHub Actions at the moment.
# See https://github.com/docker/build-push-action/issues/743
# RUN --mount=type=cache,target=./target \
#     --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
#     --mount=type=cache,target=/usr/local/rustup,sharing=locked \
#     cargo build -p $PACKAGE --release
# RUN --mount=type=cache,target=./target \
#     mv ./target/release/$PACKAGE /usr/local/bin/$PACKAGE
RUN cargo build -p $PACKAGE --release
RUN mv ./target/release/$PACKAGE /usr/local/bin/$PACKAGE

FROM debian:12-slim
ARG PACKAGE
WORKDIR /app/
COPY --from=BUILDER /usr/local/bin/$PACKAGE .
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
