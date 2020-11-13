#!/usr/bin/env bash

od=$(pwd)
mkdir -p pkg/debian/opt
mv _build/prod/rel/fireguard pkg/debian/opt/fireguard
cd pkg
dpkg-deb --build debian
mv debian.deb fireguard_amd64.deb
