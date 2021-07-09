#!/usr/bin/env bash
set -xe

ls -lR

od=$(pwd)
mkdir -p pkg/${MATRIX_OS}/opt/bin
mv cloudfire-${MATRIX_ARCH} pkg/${MATRIX_OS}/opt/bin/cloudfire
cd pkg
dpkg-deb --build ${MATRIX_OS}
mv -f ${MATRIX_OS}.deb ../cloudfire_${MATRIX_OS}_${MATRIX_ARCH}.deb
