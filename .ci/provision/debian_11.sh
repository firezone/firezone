#!/bin/bash
set -xe

export DEBIAN_FRONTEND=noninteractive

# Install prerequisites
sudo apt-get update -q
sudo apt-get install -y -q \
  dpkg-dev \
  zlib1g-dev \
  libssl-dev \
  openssl \
  bzip2 \
  procps \
  rsync \
  ca-certificates \
  build-essential \
  git \
  gnupg \
  curl \
  unzip \
  locales \
  net-tools \
  systemd

# Set locale
sudo sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen
sudo locale-gen
export LANG=en_US.UTF-8
export LANGUAGE=en_US:en
export LC_ALL=en_US.UTF-8
