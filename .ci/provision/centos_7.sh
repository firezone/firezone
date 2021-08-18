#!/bin/bash
set -ex

# CentOS 7 comes with GCC 4.8.5 which does not fully support C++14, so we need
# a newer toolchain.
sudo yum install -y centos-release-scl
sudo yum install -y devtoolset-10
source /opt/rh/devtoolset-10/enable

# Install prerequisites
sudo yum install -y \
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

# Install asdf ruby
if [ ! -d $HOME/.asdf ]; then
  git clone --depth 1 https://github.com/asdf-vm/asdf.git $HOME/.asdf
fi
grep -qxF '. $HOME/.asdf/asdf.sh' $HOME/.bashrc || echo '. $HOME/.asdf/asdf.sh' >> $HOME/.bashrc
grep -qxF '. $HOME/.asdf/completions/asdf.bash' $HOME/.bashrc || echo '. $HOME/.asdf/completions/asdf.bash' >> $HOME/.bashrc
. $HOME/.asdf/asdf.sh
asdf list ruby || asdf plugin-add ruby
cd /vagrant
asdf install

# Install omnibus
cd omnibus
gem install bundler
bundle install --binstubs

# Build omnibus package
sudo mkdir -p /opt/firezone
sudo chown -R ${USER} /opt/firezone
bin/omnibus build firezone

sudo rpm -i pkg/firezone*.rpm
