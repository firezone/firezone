#!/usr/bin/env bash
set -e

OS="redhat_8"
ARCH=${MATRIX_ARCH:-`uname -m`}
PKG_DIR="${OS}_${ARCH}"
PKG_FILE="${PKG_DIR}.rpm"
IMAGE="${OS}_${ARCH}:latest"
BASE_IMAGE="fedora:33"

docker build \
  -t $IMAGE \
  -f pkg/Dockerfile.rpm \
  --platform linux/$ARCH \
  --build-arg PKG_DIR=$PKG_DIR \
  --build-arg BASE_IMAGE=$BASE_IMAGE \
  --progress plain \
  .

CID=$(docker create $IMAGE)
mkdir -p _build
docker cp $CID:/build/pkg/$PKG_FILE ./_build/firezone_$PKG_FILE
