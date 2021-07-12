#!/usr/bin/env bash
set -e

OS="ubuntu_20.04"
ARCH=${MATRIX_ARCH:-`uname -m`}
PKG_DIR="${OS}_${ARCH}"
PKG_FILE="${PKG_DIR}.deb"
IMAGE="${OS}_${ARCH}:latest"
BASE_IMAGE="hexpm/elixir:1.12.2-erlang-24.0.3-ubuntu-focal-20210325"

docker build \
  -t $IMAGE \
  -f pkg/Dockerfile.deb \
  --platform linux/$ARCH \
  --build-arg PKG_DIR=$PKG_DIR \
  --build-arg BASE_IMAGE=$BASE_IMAGE \
  --progress plain \
  .

CID=$(docker create $IMAGE)
mkdir -p _build
docker cp $CID:/build/pkg/$PKG_FILE ./_build/firezone_$PKG_FILE
