#!/usr/bin/env bash
set -e

docker buildx build \
  --push \
  --platform linux/arm64,linux/amd64 \
  --tag ghcr.io/firezone/ubuntu:18.04 \
  --build-arg BASE_IMAGE="ubuntu:18.04" \
  --progress plain \
  -f pkg/Dockerfile.base.deb \
  .
