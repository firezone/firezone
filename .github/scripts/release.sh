#!/usr/bin/env bash
set -xe
# This script scp'd to the build host and executed to create a new release.

orig_dir=`pwd`

# Some preliminary housekeeping
rm -rf /tmp/cloudfire
mkdir -p /tmp/cloudfire
cd /tmp/cloudfire
mv ~/cloudfire_web.tar .
tar -xf cloudfire_web.tar

# Start build
echo 'Building release for system:'
uname -a

# Ensure MIX_ENV is prod throughout the build
export MIX_ENV=prod

# Set terminal to UTF-8
export LC_CTYPE="en_US.UTF-8"

# Set required env vars for the app to boot. These will not be used.
export DATABASE_URL="ecto://dummy:dummy@dummy/dummy"
export SECRET_KEY_BASE="dummy"

# Fetch dependencies, compile, compile static assets
mix local.hex --force
mix local.rebar --force
mix deps.get --only prod
mix compile
cd assets
npm install
cd ..
npm run deploy --prefix ./assets
mix phx.digest
mix release

# XXX: Append version number to release tarball
tar -zcf $HOME/release.tar.gz _build
