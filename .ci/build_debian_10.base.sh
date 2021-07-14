#!/usr/bin/env bash
set -e

platform="linux/arm64,linux/amd64,linux/arm/v7"
docker buildx build \
  --no-cache \
  --push \
  --platform $platform \
  --tag ghcr.io/firezone/debian:10 \
  --build-arg BASE_IMAGE="debian:10" \
  --progress plain \
  -f pkg/Dockerfile.base.deb \
  .
