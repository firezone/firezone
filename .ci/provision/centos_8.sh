#!/bin/bash
set -ex

# Install prerequisites
sudo yum groupinstall -y 'Development Tools'
sudo yum install -y \
  rpmdevtools \
  openssl-devel \
  openssl \
  rsync \
  bzip2 \
  procps \
  curl \
  git \
  findutils \
  unzip \
  net-tools \
  systemd

# Set locale
sudo bash -c 'echo "LANG=en_US.UTF-8" > /etc/locale.conf'
sudo localectl set-locale LANG=en_US.UTF-8

# Install WireGuard module
sudo yum install -y epel-release elrepo-release
sudo yum install -y kmod-wireguard
