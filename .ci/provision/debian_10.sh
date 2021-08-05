#!/bin/bash
set -xe

export DEBIAN_FRONTEND=noninteractive

# Install prerequisites
sudo apt-get update -q
sudo apt-get install -y -q \
  lintian \
  procps \
  zsh \
  tree \
  rsync \
  gdebi \
  ca-certificates \
  build-essential \
  git \
  dpkg-dev \
  libssl-dev \
  automake \
  gnupg \
  curl \
  autoconf \
  libncurses5-dev \
  unzip \
  zlib1g-dev \
  locales \
  net-tools \
  iptables \
  openssl \
  postgresql \
  systemd

# Set locale
sudo sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen
sudo locale-gen
export LANG=en_US.UTF-8
export LANGUAGE=en_US:en
export LC_ALL=en_US.UTF-8


# Add Backports repo
sudo bash -c 'echo "deb http://deb.debian.org/debian buster-backports main" > /etc/apt/sources.list.d/backports.list'
sudo apt-get -q update


# Install WireGuard
sudo apt-get install -y -q wireguard


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
sudo mkdir /opt/firezone
sudo chown -R ${USER} /opt/firezone
bin/omnibus build firezone
