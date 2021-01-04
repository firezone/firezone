#!/usr/bin/env bash
set -e

od=$(pwd)
mkdir -p pkg/debian/opt
rsync --delete -a _build/prod/rel/fireguard pkg/debian/opt/
cd pkg
dpkg-deb --build debian
mv -f debian.deb ../fireguard_amd64.deb
