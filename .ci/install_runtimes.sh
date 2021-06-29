#!/usr/bin/env bash
set -e

os_name='ubuntu~bionic'

curl -O https://packages.erlang-solutions.com/erlang/debian/pool/esl-erlang_24.0.2-1~${os_name}_${arch}.deb
curl -O https://packages.erlang-solutions.com/erlang/debian/pool/elixir_1.12.0-1~${os_name}_all.deb
dpkg -i *.deb

apt-get install --fix-missing

curl -sL https://deb.nodesource.com/setup_14.x | bash -
apt-get install gcc g++ make nodejs
