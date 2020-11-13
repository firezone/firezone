#!/usr/bin/env bash

od=$(pwd)
export MIX_ENV=prod
mix local.hex --force && mix local.rebar --force
mix do deps.get, deps.compile
cd apps/fg_http/assets && npm ci --progress=false --no-audit --loglevel=error
cd $od
npm run --prefix apps/fg_http/assets deploy
cd apps/fg_http
mix phx.digest
cd $od
mix release fireguard
