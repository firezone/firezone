#!/usr/bin/env bash
set -xe

od=$(pwd)
mkdir -p pkg/${MATRIX_OS}/opt/cloudfire/bin
mv cloudfire-${MATRIX_ARCH} pkg/${MATRIX_OS}/opt/cloudfire/bin/cloudfire
cd pkg
dpkg-deb --build ${MATRIX_OS}_${MATRIX_ARCH}
mv -f *.deb ../cloudfire_${MATRIX_OS}_${MATRIX_ARCH}.deb
