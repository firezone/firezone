#!/usr/bin/env bash
set -e

docker buildx build \
  --push \
  --platform linux/arm64,linux/amd64 \
  --tag ghcr.io/firezone/centos:8 \
  --build-arg BASE_IMAGE="centos:8" \
  --progress plain \
  -f pkg/Dockerfile.base.rpm \
  .
