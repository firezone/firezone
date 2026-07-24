#!/usr/bin/env bash

set -euo pipefail

target="${1:?usage: pack-corpus.sh <target>}"
corpus="corpus/$target"
archive="corpora/$target.tar.gz"

mkdir -p corpora
temporary="$(mktemp "corpora/.$target.XXXXXX")"
trap 'rm -f "$temporary"' EXIT

tar \
    --sort=name \
    --mtime=@0 \
    --owner=0 \
    --group=0 \
    --numeric-owner \
    --format=ustar \
    -cf - \
    -C "$corpus" . |
    gzip -n > "$temporary"

mv "$temporary" "$archive"
chmod 0644 "$archive"
