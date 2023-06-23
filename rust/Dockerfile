FROM rust:1.70-slim as BUILDER
ARG PACKAGE
WORKDIR /build/
COPY . ./
RUN --mount=type=cache,target=./target \
    --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/rustup \
    apt update && apt install -y musl-tools && \
    cargo build -p $PACKAGE --release --target x86_64-unknown-linux-musl

RUN --mount=type=cache,target=./target \
    mv ./target/x86_64-unknown-linux-musl/release/$PACKAGE /usr/local/bin/$PACKAGE

FROM alpine:3.18
ARG PACKAGE
WORKDIR /app/
COPY --from=BUILDER /usr/local/bin/$PACKAGE .
ENV RUST_BACKTRACE=1
ENV PATH "/app:$PATH"
ENV PACKAGE_NAME ${PACKAGE}
CMD ${PACKAGE_NAME}
