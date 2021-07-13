#!/usr/bin/env bash
set -e

docker build \
  -t ghcr.io/firezone/debian:10 \
  -f pkg/Dockerfile.base.deb \
  --build-arg BASE_IMAGE="debian:10" \
  --progress plain \
  .
