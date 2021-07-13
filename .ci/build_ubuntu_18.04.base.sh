#!/usr/bin/env bash
set -e

docker build \
  -t ghcr.io/firezone/ubuntu:18.04 \
  -f pkg/Dockerfile.base.deb \
  --build-arg BASE_IMAGE="ubuntu:18.04" \
  --progress plain \
  .
