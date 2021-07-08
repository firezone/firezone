#!/usr/bin/env bash
set -e

od=$(pwd)
mkdir -p pkg/${MATRIX_OS}/opt/bin
rsync --delete -a _build/prod/rel/bakeware/cloudfire pkg/${MATRIX_OS}/opt/bin/
cd pkg
dpkg-deb --build ${MATRIX_OS}
mv -f ${MATRIX_OS}.deb ../cloudfire_${MATRIX_OS}_${MATRIX_ARCH}.deb
