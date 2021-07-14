#!/usr/bin/env bash
set -e

platform="linux/arm64,linux/amd64,linux/arm/v7"
docker buildx build \
  --no-cache \
  --push \
  --platform linux/arm64,linux/amd64 \
  --tag ghcr.io/firezone/centos:8 \
  --build-arg BASE_IMAGE="centos:8" \
  --progress plain \
  -f pkg/Dockerfile.base.rpm \
  .
