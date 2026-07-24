#!/usr/bin/env bash

set -euo pipefail

target="${1:?usage: unpack-corpus.sh <target>}"
archive="corpora/$target.tar.gz"
corpus="corpus/$target"

mkdir -p "$corpus"
tar -xzf "$archive" -C "$corpus"
