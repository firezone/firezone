#!/usr/bin/env bash
set -e

docker build \
  -t ghcr.io/firezone/fedora:34 \
  -f pkg/Dockerfile.base.rpm \
  --build-arg BASE_IMAGE="fedora:34" \
  --progress plain \
  .
