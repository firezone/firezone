#!/usr/bin/env sh
set -e

export root=`pwd`

apt-get update -q && \
  apt-get install -y --no-install-recommends \
  build-essential \
  git \
  curl \
  libssl-dev \
  automake \
  lintian \
  dpkg-dev \
  gnupg \
  autoconf \
  libncurses5-dev \
  unzip \
  zlib1g-dev

git clone --depth 1 https://github.com/asdf-vm/asdf.git $HOME/.asdf
export PATH="${PATH}:/root/.asdf/shims:/root/.asdf/bin"
bash $HOME/.asdf/asdf.sh

# Install project runtimes
asdf plugin-add erlang && \
  asdf plugin-update erlang && \
  asdf plugin-add elixir && \
  asdf plugin-update elixir && \
  asdf plugin-add nodejs && \
  asdf plugin-update nodejs && \
  asdf plugin-add python && \
  asdf plugin-update python
bash -c '${ASDF_DATA_DIR:=$HOME/.asdf}/plugins/nodejs/bin/import-release-team-keyring'
asdf install

# Set build env vars
export MIX_ENV=prod

# Install dependencies
mix local.hex --force
mix local.rebar --force
mix do deps.get, deps.compile

# Compile assets
cd $root/apps/fg_http/assets && npm i --progress=false --no-audit --loglevel=error
cd $root/apps/fg_http/assets && npm run deploy && cd .. && mix phx.digest

# Build the release
cd $root && mix release fireguard

# Move release for packaging
mv ./_build/prod/rel/fireguard ./pkg/debian/opt/fireguard

# Smoke test
export DATABASE_URL=ecto://dummy@localhost/dummy
export SECRET_KEY_BASE=dummy
./pkg/debian/opt/fireguard/bin/fireguard eval 'IO.puts "hello world"'

# Build package
cd $root/pkg && dpkg-deb --build debian
mv pkg/debian.deb fireguard_0.1.0-1_amd64.deb

# TODO: This reports too many issues... :-(
# RUN lintian fireguard_0.1.0-1_amd64.deb
