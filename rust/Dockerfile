FROM rust:1.70-slim as BUILDER
ARG PACKAGE
WORKDIR /build/
COPY . ./
RUN --mount=type=cache,target=./target \
    --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/rustup,sharing=locked \
    cargo build -p $PACKAGE --release

RUN --mount=type=cache,target=./target \
    mv ./target/release/$PACKAGE /usr/local/bin/$PACKAGE

FROM debian:11.7-slim
ARG PACKAGE
WORKDIR /app/
COPY --from=BUILDER /usr/local/bin/$PACKAGE .
RUN ln -s ./${PACKAGE} ./app
COPY ./docker-init.sh .
ENV RUST_BACKTRACE=1
ENV PATH "/app:$PATH"
ENV PACKAGE_NAME ${PACKAGE}
RUN apt-get update -y \
    && apt-get install -y iputils-ping iptables lsof iproute2 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

ENTRYPOINT ["docker-init.sh"]
CMD ["app"]
