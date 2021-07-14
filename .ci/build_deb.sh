#!/usr/bin/env bash
set -e

OS=$1
BASE_IMAGE=$2
ARCH=${MATRIX_ARCH:-`uname -m`}
PKG_DIR="${OS}_${ARCH}"
PKG_FILE="${PKG_DIR}.deb"
IMAGE="${OS}_${ARCH}:latest"

docker build \
  -t $IMAGE \
  -f pkg/Dockerfile.deb \
  --platform linux/$ARCH \
  --build-arg PLATFORM=linux/$ARCH \
  --build-arg PKG_DIR=$PKG_DIR \
  --build-arg BASE_IMAGE=$BASE_IMAGE \
  --progress plain \
  .

CID=$(docker create $IMAGE)
mkdir -p _build
docker cp $CID:/root/pkg/$PKG_FILE ./_build/firezone_$PKG_FILE
