#!/usr/bin/env bash
set -e

filename="fireguard_${GITHUB_SHA}-1_${MATRIX_OS}_amd64.deb"
mv fireguard_${MATRIX_OS}_amd64.deb ./${filename}
