#!/usr/bin/env bash
set -e

od=$(pwd)
mix local.hex --force && mix local.rebar --force
mix do deps.get, deps.compile
cd apps/cf_http/assets && npm ci --progress=false --no-audit --loglevel=error
cd $od
npm run --prefix apps/cf_http/assets deploy
cd apps/cf_http
mix phx.digest
cd $od
mix release --overwrite --force cloudfire
