#!/usr/bin/env bash
set -e

docker buildx build \
  --no-cache \
  --push \
  --platform linux/arm64,linux/amd64 \
  --tag ghcr.io/firezone/fedora:34 \
  --build-arg BASE_IMAGE="fedora:34" \
  --progress plain \
  -f pkg/Dockerfile.base.rpm \
  .
