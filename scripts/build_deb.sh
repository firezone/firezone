#!/usr/bin/env bash
set -e

od=$(pwd)
mkdir -p pkg/ubuntu-20.04/opt
rsync --delete -a _build/prod/rel/fireguard pkg/ubuntu-20.04/opt/
cd pkg
dpkg-deb --build ubuntu-20.04
mv -f ubuntu-20.04.deb ../fireguard_ubuntu-20.04_amd64.deb
