#!/usr/bin/env bash
set -e

os_name='ubuntu~bionic'

curl -O https://packages.erlang-solutions.com/erlang/debian/pool/esl-erlang_24.0.2-1~${os_name}_${MATRIX_ARCH}.deb
curl -O https://packages.erlang-solutions.com/erlang/debian/pool/elixir_1.12.0-1~${os_name}_all.deb
gdebi --non-interactive *.deb

curl -sL https://deb.nodesource.com/setup_14.x | bash -
apt-get install -y -q gcc g++ make nodejs
