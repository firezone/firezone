#!/usr/bin/env bash
set -e

os_name='ubuntu~bionic'

apt-get install wget

wget -O erlang.deb https://packages.erlang-solutions.com/erlang/debian/pool/esl-erlang_24.0.2-1~${os_name}_${arch}.deb
wget -O elixir.deb https://packages.erlang-solutions.com/erlang/debian/pool/elixir_1.12.0-1~${os_name}_all.deb
dpkg -i erlang.deb
dpkg -i elixir.deb

apt-get install --fix-missing

curl -sL https://deb.nodesource.com/setup_14.x | bash -
