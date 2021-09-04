#!/bin/bash
set -ex

# CentOS 7 comes with GCC 4.8.5 which does not fully support C++14, so we need
# a newer toolchain.
sudo yum install -y centos-release-scl
sudo yum install -y devtoolset-9
source /opt/rh/devtoolset-9/enable

# Install prerequisites
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
sudo yum install -y yum-plugin-elrepo
sudo yum install -y kmod-wireguard
