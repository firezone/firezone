#!/bin/bash
set -e

docker build \
  -t ghcr.io/firezone/amazonlinux:2 \
  -f pkg/Dockerfile.base.rpm \
  --build-arg BASE_IMAGE="amazonlinux:2" \
  --progress plain \
  .
docker push ghcr.io/firezone/amazonlinux:2


docker build \
  -t ghcr.io/firezone/centos:7 \
  -f pkg/Dockerfile.base.rpm \
  --build-arg BASE_IMAGE="centos:7" \
  --progress plain \
  .
docker push ghcr.io/firezone/centos:7


docker build \
  -t ghcr.io/firezone/centos:8 \
  -f pkg/Dockerfile.base.rpm \
  --build-arg BASE_IMAGE="centos:8" \
  --progress plain \
  .
docker push ghcr.io/firezone/centos:8


docker build \
  -t ghcr.io/firezone/fedora:33 \
  -f pkg/Dockerfile.base.rpm \
  --build-arg BASE_IMAGE="fedora:33" \
  --progress plain \
  .
docker push ghcr.io/firezone/fedora:33


docker build \
  -t ghcr.io/firezone/fedora:34 \
  -f pkg/Dockerfile.base.rpm \
  --build-arg BASE_IMAGE="fedora:34" \
  --progress plain \
  .
docker push ghcr.io/firezone/fedora:34


docker build \
  -t ghcr.io/firezone/fedora:35 \
  -f pkg/Dockerfile.base.rpm \
  --build-arg BASE_IMAGE="fedora:35" \
  --progress plain \
  .
docker push ghcr.io/firezone/fedora:35


docker build \
  -t ghcr.io/firezone/debian:10 \
  -f pkg/Dockerfile.base.deb \
  --build-arg BASE_IMAGE="debian:10" \
  --progress plain \
  .
docker push ghcr.io/firezone/debian:10


docker build \
  -t ghcr.io/firezone/ubuntu:18.04 \
  -f pkg/Dockerfile.base.deb \
  --build-arg BASE_IMAGE="ubuntu:18.04" \
  --progress plain \
  .
docker push ghcr.io/firezone/ubuntu:18.04


docker build \
  -t ghcr.io/firezone/ubuntu:20.04 \
  -f pkg/Dockerfile.base.deb \
  --build-arg BASE_IMAGE="ubuntu:20.04" \
  --progress plain \
  .
docker push ghcr.io/firezone/ubuntu:20.04
