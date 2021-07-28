#!/bin/bash
set -e

# Mimics CI build action to build local packages

# Required due to a buildx bug.
# See https://github.com/docker/buildx/issues/495#issuecomment-761562905
if [ `uname -m` = "amd64" ]; then
  docker buildx rm multiarch || true
  docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
  docker buildx create --name multiarch --driver docker-container --use
  docker buildx inspect --bootstrap
elif [ `uname -m` = "arm64" ]; then
  docker buildx create --use
fi

# If MATRIX_IMAGE is defined, build it, otherwise build all
if [ -n "$MATRIX_IMAGE" ]; then
  .ci/build_packages.sh
else
  declare -a matrix_images=("centos:7"
  "centos:8"
  "fedora:33"
  "fedora:34"
  "debian:10"
  "ubuntu:18.04"
  "ubuntu:20.04"
  )

  for image in "${matrix_images[@]}"; do
    # Mimic CI pipeline variables
    export GITHUB_SHA=$(git rev-parse --short HEAD)
    export MATRIX_IMAGE=$image

    .ci/build_packages.sh &
  done
fi
