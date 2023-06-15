# syntax=docker/dockerfile:1.5-labs
FROM rust:1.70-slim as builder

WORKDIR /workspace
ADD . .
RUN --mount=type=cache,target=./target \
    --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/rustup \
    rustup target add x86_64-unknown-linux-musl && \
    cargo build --release --bin relay --target x86_64-unknown-linux-musl

RUN --mount=type=cache,target=./target \
    mv ./target/x86_64-unknown-linux-musl/release/relay /usr/local/bin/relay

FROM scratch
COPY --from=builder /usr/local/bin/relay /usr/local/bin/relay
ENV RUST_BACKTRACE=1

EXPOSE 3478/udp
EXPOSE 49152-65535/udp

# This purposely does not include an `init` process. Use `docker run --init` instead.
ENTRYPOINT ["relay"]
