#!/usr/bin/env bash
set -e

docker buildx build \
  --no-cache \
  --push \
  --platform linux/arm64,linux/amd64 \
  --tag ghcr.io/firezone/debian:10 \
  --build-arg BASE_IMAGE="debian:10" \
  --progress plain \
  -f pkg/Dockerfile.base.deb \
  .
