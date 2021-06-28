#!/usr/bin/env bash
set -e

filename="cloudfire_${GITHUB_SHA}-1_${MATRIX_OS}_amd64.deb"
mv cloudfire_${MATRIX_OS}_amd64.deb ./${filename}
