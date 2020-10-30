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

bash scripts/install_asdf.sh

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
