#!/bin/bash
set -xe

export DEBIAN_FRONTEND=noninteractive

# Install prerequisites
sudo apt-get update -q
sudo apt-get install -y -q \
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


# Add Backports repo
sudo bash -c 'echo "deb http://deb.debian.org/debian buster-backports main" > /etc/apt/sources.list.d/backports.list'
sudo apt-get -q update

# Install NodeJS 16
curl -fsSL https://deb.nodesource.com/setup_16.x | sudo -E bash -
sudo apt-get install -y nodejs


# Install WireGuard
sudo apt-get install -y -q wireguard-dkms


# Install asdf
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
CC=/usr/bin/gcc-10 bin/omnibus build firezone

sudo dpkg -i pkg/firezone*.deb
