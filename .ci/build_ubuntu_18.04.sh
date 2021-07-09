#!/usr/bin/env bash
set -e

OS="ubuntu_18.04"
ARCH=${MATRIX_ARCH:-`uname -m`}
PKG_DIR="${OS}_${ARCH}"
PKG_FILE="${PKG_DIR}.deb"
IMAGE="${OS}_${ARCH}:latest"

docker build \
  -t $IMAGE \
  -f pkg/Dockerfile.$OS \
  --platform linux/$ARCH \
  --build-arg PKG_DIR=$PKG_DIR \
  --progress plain \
  .

CID=$(docker create $IMAGE)
mkdir -p _build
docker cp $CID:/build/pkg/$PKG_FILE ./_build/

echo "Listing build dir: $(ls _build)"
