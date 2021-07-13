#!/usr/bin/env bash
set -e

docker build \
  -t ghcr.io/firezone/fedora:35 \
  -f pkg/Dockerfile.base.rpm \
  --build-arg BASE_IMAGE="fedora:35" \
  --progress plain \
  .
