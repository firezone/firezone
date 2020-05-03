#!/usr/bin/env bash
set -e

# This file provisions the vagrant vm with needed tools to develop
# and test a single-host CloudFire instance.

# Add WireGuard PPA
add-apt-repository ppa:wireguard/wireguard

# Add required packages
apt-get update

# These are from the Docker build-pack and erlang Dockerfiles
apt-get install -y --no-install-recommends \
  libodbc1 \
  libsctp1 \
  libwxgtk3.0 \
  unixodbc-dev \
  libsctp-dev \
  autoconf \
  automake \
  bzip2 \
  dpkg-dev \
  file \
  g++ \
  gcc \
  imagemagick \
  libbz2-dev \
  libc6-dev \
  libcurl4-openssl-dev \
  libdb-dev \
  libevent-dev \
  libffi-dev \
  libgdbm-dev \
  libglib2.0-dev \
  libgmp-dev \
  libjpeg-dev \
  libkrb5-dev \
  liblzma-dev \
  libmagickcore-dev \
  libmagickwand-dev \
  libmaxminddb-dev \
  libncurses5-dev \
  libncursesw5-dev \
  libpng-dev \
  libpq-dev \
  libreadline-dev \
  libsqlite3-dev \
  libssl-dev \
  libtool \
  libwebp-dev \
  libxml2-dev \
  libxslt-dev \
  libyaml-dev \
  make \
  patch \
  unzip \
  xz-utils \
  zlib1g-dev \
  git \
  libwxgtk3.0-dev \
  wireguard wireguard-tools wireguard-dkms \
  nftables
