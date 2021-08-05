#!/bin/bash
set -ex

# Install prerequisites
sudo yum groupinstall -y 'Development Tools'
sudo yum install -y \
  gcc-c++ \
  zsh \
  tree \
  rsync \
  autoconf \
  automake \
  procps \
  openssl-devel \
  ncurses-devel \
  curl \
  git \
  findutils \
  unzip \
  glibc-all-langpacks \
  rpmdevtools \
  rpmlint \
  openssl \
  net-tools \
  systemd \
  iptables

# Set locale
sudo bash -c 'echo "LANG=en_US.UTF-8" > /etc/locale.conf'
sudo localectl set-locale LANG=en_US.UTF-8


# Install asdf
git clone --depth 1 https://github.com/asdf-vm/asdf.git $HOME/.asdf
echo '. $HOME/.asdf/asdf.sh' >> $HOME/.bashrc
echo '. $HOME/.asdf/completions/asdf.bash' >> $HOME/.bashrc
. $HOME/.asdf/asdf.sh
asdf plugin-add ruby
cd /vagrant
asdf install

# Install omnibus
cd omnibus
gem install bundler
bundle install --binstubs


# Build omnibus package
bin/omnibus build firezone
