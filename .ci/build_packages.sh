#!/usr/bin/env bash
set -xe

version=0.2.0-1
base_image="ghcr.io/firezone/${MATRIX_IMAGE}"
pkg_file="firezone-${version}-${MATRIX_IMAGE/:/_}.amd64.tar.gz"
image="firezone-${version}-${MATRIX_IMAGE/:/_}:${GITHUB_SHA}"

docker build \
  --no-cache \
  --pull \
  -t $image \
  -f pkg/Dockerfile.release \
  --platform linux/amd64 \
  --build-arg PKG_FILE=$pkg_file \
  --build-arg BASE_IMAGE=$base_image \
  .

cid=$(docker create $image)
mkdir -p _build
docker cp $cid:/root/$pkg_file ./_build/$pkg_file
