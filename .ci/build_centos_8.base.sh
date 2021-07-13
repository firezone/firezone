#!/usr/bin/env bash
set -e

docker build \
  -t ghcr.io/firezone/centos:8 \
  -f pkg/Dockerfile.base.rpm \
  --build-arg BASE_IMAGE="centos:8" \
  --progress plain \
  .
