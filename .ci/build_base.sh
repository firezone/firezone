#!/usr/bin/env bash
set -xe

case $MATRIX_IMAGE in
  centos*)
    format="rpm"
    ;;
  fedora*)
    format="rpm"
    ;;
  debian*)
    format="deb"
    ;;
  ubuntu*)
    format="deb"
    ;;
esac

docker buildx build \
  --pull \
  --push \
  --platform linux/amd64 \
  --tag ghcr.io/firezone/$MATRIX_IMAGE \
  --build-arg BASE_IMAGE=$MATRIX_IMAGE \
  --progress plain \
  -f pkg/Dockerfile.base.$format \
  .
