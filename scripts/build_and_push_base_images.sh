#!/bin/bash
set -e

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
.ci/build_amazonlinux_2.base.sh
.ci/build_centos_7.base.sh
.ci/build_centos_8.base.sh
.ci/build_fedora_33.base.sh
.ci/build_fedora_34.base.sh
.ci/build_fedora_35.base.sh
.ci/build_debian_10.base.sh
.ci/build_ubuntu_18.04.base.sh
.ci/build_ubuntu_20.04.base.sh
