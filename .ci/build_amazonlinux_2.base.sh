#!/usr/bin/env bash
set -e

docker build \
  -t ghcr.io/firezone/amazonlinux:2 \
  -f pkg/Dockerfile.base.rpm \
  --build-arg BASE_IMAGE="amazonlinux:2" \
  --progress plain \
  .
