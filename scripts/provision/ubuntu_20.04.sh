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
  systemd \
  wireguard \
  wireguard-tools

# Set locale
sudo sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen
sudo locale-gen
export LANG=en_US.UTF-8
export LANGUAGE=en_US:en
export LC_ALL=en_US.UTF-8

# Set up Postgres
sudo systemctl enable postgresql
sudo systemctl start postgresql


# Install asdf
git clone --depth 1 https://github.com/asdf-vm/asdf.git $HOME/.asdf
echo '. $HOME/.asdf/asdf.sh' >> $HOME/.bashrc
echo '. $HOME/.asdf/completions/asdf.bash' >> $HOME/.bashrc
source $HOME/.bashrc
asdf plugin-add nodejs
asdf plugin-add erlang
asdf plugin-add elixir
asdf install


# Build release
export MIX_ENV=prod
mix local.hex --force
mix local.rebar --force
mix deps.get --only prod
mix deps.compile
npm ci --prefix apps/fz_http/assets --progress=false --no-audit --loglevel=error
npm run --prefix ./apps/fz_http/assets deploy
od=$pwd && cd apps/fz_http && mix phx.digest && cd $od
mix release
tar -zcf $PKG_FILE -C _build/prod/rel/ firezone

# file=(/tmp/firezone*.tar.gz)
# /tmp/install.sh /tmp/$file
# systemctl start firezone || true
# systemctl status firezone.service
# journalctl -xeu firezone
