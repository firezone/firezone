#!/bin/bash
set -ex

# CentOS 7 comes with GCC 4.8.5 which does not fully support C++14, so we need
# a newer toolchain.
sudo yum install -y centos-release-scl
sudo yum install -y devtoolset-9
source /opt/rh/devtoolset-9/enable

# Install prerequisites
sudo yum install -y \
  tree \
  rsync \
  procps \
  openssl-devel \
  ncurses-devel \
  curl \
  git \
  findutils \
  python3 \
  unzip \
  rpmdevtools \
  rpmlint \
  openssl \
  net-tools \
  systemd \
  iptables

# Set locale
sudo bash -c 'echo "LANG=en_US.UTF-8" > /etc/locale.conf'
sudo localectl set-locale LANG=en_US.UTF-8

# Install NodeJS 16
curl -fsSL https://rpm.nodesource.com/setup_16.x | sudo bash -

# Install WireGuard
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
