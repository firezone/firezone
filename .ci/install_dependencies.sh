#!/usr/bin/env bash
set -e

mix deps.get --only test
cd apps/fz_http/assets
npm install
./node_modules/.bin/webpack --mode development
