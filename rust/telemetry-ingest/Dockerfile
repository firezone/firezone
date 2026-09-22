# The build context is `rust/`: the crate resolves its dependencies through the
# workspace manifest, so the whole workspace has to be present.

ARG RUST_VERSION="1.98.1" # Keep in sync with `rust-toolchain.toml`.

FROM rust:${RUST_VERSION} AS builder

WORKDIR /build
COPY . .
RUN cargo build --release -p telemetry-ingest

FROM debian:bookworm-slim AS runtime

## Forwarding to Azure Monitor is HTTPS, so the image needs the CA bundle.
RUN apt-get update \
    && apt-get install --no-install-recommends --yes ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/target/release/telemetry-ingest /usr/local/bin/telemetry-ingest

ENV RUST_LOG=info
EXPOSE 8080
USER nobody

ENTRYPOINT ["telemetry-ingest"]
