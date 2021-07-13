#!/usr/bin/env bash
set -e

docker buildx build \
  --push \
  --platform linux/arm64,linux/amd64 \
  --tag ghcr.io/firezone/centos:7 \
  --build-arg BASE_IMAGE="centos:7" \
  --progress plain \
  -f pkg/Dockerfile.base.rpm \
  .
