#!/usr/bin/env bash
set -e

OS=$1
BASE_IMAGE=$2
ARCH=${MATRIX_ARCH:-`uname -m`}
IMAGE="${OS}_${ARCH}:latest"
VERSION=0.2.0-1
RPM_ARCH="${ARCH/arm64/aarch64}"
PKG_DIR="firezone-${VERSION}.${RPM_ARCH}"
PKG_FILE="${PKG_DIR}.rpm"

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
docker cp $CID:/root/rpmbuild/RPMS/$RPM_ARCH/$PKG_FILE ./_build/$PKG_FILE
