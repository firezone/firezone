#!/usr/bin/env bash
set -xe

base_image="ghcr.io/firezone/${MATRIX_IMAGE}"
tag="ghcr.io/firezone/release-${MATRIX_IMAGE/:/_}:${GITHUB_SHA}"

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

# Build intermediate release image
docker buildx build \
  --pull \
  --push \
  -f pkg/Dockerfile.release \
  -t $tag \
  --platform linux/amd64 \
  --build-arg BASE_IMAGE=$base_image \
  --progress plain \
  .



case $format in
  deb)
    version=0.2.0-1
    pkg_dir="${MATRIX_IMAGE/:/_}.amd64"
    pkg_file="${pkg_dir}.deb"
    final_pkg_file="firezone-${version}-${pkg_file}"
    image="ghcr.io/firezone/package-${MATRIX_IMAGE/:/_}:${GITHUB_SHA}"

    docker buildx build \
      --pull \
      --push \
      --tag $image \
      -f pkg/Dockerfile.deb \
      --platform linux/amd64 \
      --build-arg PKG_DIR=$pkg_dir \
      --build-arg BASE_IMAGE=$tag \
      --progress plain \
      .

    cid=$(docker create $image)
    mkdir -p _build
    docker cp $cid:/root/$pkg_file ./_build/$final_pkg_file
    ;;

  rpm)
    version=0.2.0-1
    pkg_dir="firezone-${version}.x86_64"
    pkg_file="${pkg_dir}.rpm"
    os_dir="${MATRIX_IMAGE/:/_}.x86_64"
    final_pkg_file="firezone-${version}-${MATRIX_IMAGE/:/_}.x86_64.rpm"
    image="ghcr.io/firezone/package-${MATRIX_IMAGE/:/_}:${GITHUB_SHA}"

    docker buildx build \
      --pull \
      --push \
      -t $image \
      -f pkg/Dockerfile.rpm \
      --platform linux/amd64 \
      --build-arg PKG_DIR=$pkg_dir \
      --build-arg OS_DIR=$os_dir \
      --build-arg BASE_IMAGE=$tag \
      --progress plain \
      .

    cid=$(docker create $image)
    mkdir -p _build
    docker cp $cid:/root/rpmbuild/RPMS/x86_64/$pkg_file ./_build/$final_pkg_file
    ;;
esac
