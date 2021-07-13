#!/usr/bin/env bash
set -e

docker buildx build \
  --no-cache \
  --push \
  --platform linux/arm64,linux/amd64 \
  --tag ghcr.io/firezone/amazonlinux:2 \
  --build-arg BASE_IMAGE="amazonlinux:2" \
  --progress plain \
  -f pkg/Dockerfile.base.rpm \
  .
