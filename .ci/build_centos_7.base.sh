#!/usr/bin/env bash
set -e

docker build \
  -t ghcr.io/firezone/centos:7 \
  -f pkg/Dockerfile.base.rpm \
  --build-arg BASE_IMAGE="centos:7" \
  --progress plain \
  .
