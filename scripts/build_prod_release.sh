#!/usr/bin/env bash

od=$(pwd)
export MIX_ENV=prod

cd apps/fg_http
npm run deploy --prefix assets
mix phx.digest

cd $od
mix release
