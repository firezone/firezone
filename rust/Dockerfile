FROM lukemathwalker/cargo-chef:latest-rust-1.72-slim-bookworm as chef
WORKDIR /build

FROM chef as planner

COPY . .
RUN cargo chef prepare --recipe-path recipe.json

FROM chef as builder

COPY --from=planner /build/recipe.json recipe.json
RUN cargo chef cook --release --recipe-path recipe.json
COPY . .

ARG PACKAGE
RUN cargo build -p $PACKAGE --release
RUN mv ./target/release/$PACKAGE /usr/local/bin/$PACKAGE

FROM debian:bookworm-slim AS runtime

WORKDIR /app

ARG PACKAGE
COPY --from=builder /usr/local/bin/$PACKAGE .
RUN ln -s ./${PACKAGE} ./app

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

ENV RUST_BACKTRACE=1
ENV PATH "/app:$PATH"
ENV PACKAGE_NAME ${PACKAGE}

COPY ./docker-init.sh .
ENTRYPOINT ["docker-init.sh"]

CMD ["app"]
